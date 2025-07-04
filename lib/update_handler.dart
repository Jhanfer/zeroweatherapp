import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:package_info_plus/package_info_plus.dart";
import "package:path_provider/path_provider.dart";
import "package:permission_handler/permission_handler.dart";
import "package:flutter_downloader/flutter_downloader.dart";
import "package:open_filex/open_filex.dart";

class UpdateScreenState with ChangeNotifier {
  static final UpdateScreenState _instance = UpdateScreenState._internal();
  factory UpdateScreenState() => _instance;
  UpdateScreenState._internal();

  int dprogress = 0;

  ReceivePort? _port;
  var filePath = "";

  final _eventController = StreamController<Map>.broadcast();
  Stream<Map> get eventStream => _eventController.stream;

  final _downloadEventController = StreamController<Map>.broadcast();
  Stream<Map> get downloadEventStream => _downloadEventController.stream;

  void emitEvent(Map event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void initialize(ReceivePort port) {
    _port = port;
    _port!.listen((data) {
      final id = data[0] as String;
      final status = data[1] as int;
      final progress = data[2] as int;

      emitDownloadProgress(id, status, progress);
    });
  }

  void emitDownloadProgress(String id, int status, int progress) {
    _downloadEventController.add({
      "id": id,
      "status": status,
      "progress": progress,
    });
  }

  String _status = "Verificando actualizaciones...";
  String globalApkUrl = "";
  String currentVersion = "";

  int _parseInt(String s) {
    try {
      return int.parse(s);
    } catch (e) {
      return 0;
    }
  }

  var currentversion = "";
  Future<void> getCurrentVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = packageInfo.version;
    currentversion = currentVersion;
  }

  Future<void> checkForUpdates() async {
    try {
      // Obtener la versión actual de la app
      await getCurrentVersion();

      // Consultar version.json en Google Drive
      final response = await http.get(
        Uri.parse(
          "https://drive.google.com/uc?export=download&id=1gLmc96KSw4R78y27EsZ99fPx5aGVSbRW",
        ),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String latestVersion = data["version"];
        String apkUrl = data["apk_url"];
        globalApkUrl = apkUrl;
        bool forceUpdate = data["force_update"];

        // Comparar versiones

        //se divide por el punto y se hace un parseo de los numeros a enteros con el iterable "map" para poder compararlos de manera individual
        var v1 = currentversion.split(".").map(_parseInt).toList();
        var v2 = latestVersion.split(".").map(_parseInt).toList();

        // se recorre la lista de versiones para compararlas
        for (int i = 0; i < v1.length; i++) {
          // aqui lo que se hace es recorrer las listas, osea, los numeros de las versiones. Se recorre segun el tamaño de la lista (3), si una lista tiene menos elementos, se rellena con 0. Después se compara cada elemento de la lista, si el elemento de la lista 1 es mayor que el elemento de la lista 2, se devuelve true, indicando que la version 1 es mayor que la version 2
          int part1 = i < v1.length ? v1[i] : 0;
          int part2 = i < v2.length ? v2[i] : 0;

          if (part1 < part2) {
            emitEvent({
              "show_update_dialog": {
                "apkUrl": apkUrl,
                "latestVersion": latestVersion,
                "forceUpdate": forceUpdate,
              },
            });
          }
          if (part1 > part2) {
            {
              _status = "App actualizada (versión $currentversion)";
              debugPrint(_status);
            }
          }
        }
      } else {
        _status = "Error al verificar actualizaciones";
        debugPrint(_status);
      }
    } catch (e) {
      _status = "Error: $e";
      debugPrint(_status);
    }
  }

  Future<void> downloadAndInstallApkAlt() async {
    // Solicitar permisos de almacenamiento
    var storagePermission = await Permission.manageExternalStorage.request();

    if (storagePermission.isGranted) {
      _status = "Descargando actualización...";

      // Obtener el directorio de descargas
      final directory = await getExternalStorageDirectory();
      final savedDir = directory!.path;
      filePath = "$savedDir/app-release.apk";

      await FlutterDownloader.cancelAll();
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint("Archivo parcial eliminado: $filePath");
      }

      _eventController.add({
        "show_donwload_progress": {
          "status": "Descargando actualización...",
          "progress": 0,
        },
      });

      // Crear un Completer para esperar la finalización de la descarga
      final completer = Completer<void>();
      StreamSubscription<Map>? subscription;
      subscription = _eventController.stream.listen((event) {
        if (event.containsKey("id") &&
            event["status"] == DownloadTaskStatus.complete.index) {
          completer.complete();
          subscription?.cancel();
        } else if (event.containsKey("id") &&
            (event["status"] == DownloadTaskStatus.failed.index ||
                event["status"] == DownloadTaskStatus.canceled.index)) {
          completer.completeError(Exception("Descarga fallida o cancelada"));
          subscription?.cancel();
        }
      });

      // Descargar el APK
      await FlutterDownloader.enqueue(
        url: globalApkUrl,
        savedDir: savedDir,
        fileName: "app-release.apk",
        showNotification: true,
        openFileFromNotification: true,
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; FlutterDownloader/1.0)",
          "Accept": "application/vnd.android.package-archive",
        },
      );

      // Esperar a que la descarga se complete
      try {
        await completer.future;
        debugPrint("Descarga completada, iniciando instalación");
        await installApk();
      } catch (e) {
        _eventController.add({"error": "Error: $e"});
      }
    } else {
      _status = "Permisos de almacenamiento denegados";
      _eventController.add({"error": "Permisos de almacenamiento denegados"});
    }
    notifyListeners();
  }

  Future<void> installApk() async {
    // Solicitar permiso para instalar apps
    if (await Permission.requestInstallPackages.request().isGranted &&
        await File(filePath).exists()) {
      final result = await OpenFilex.open(filePath);
      _status = "Instalación iniciada: ${result.message}";
      debugPrint(_status);
    } else {
      _status = "Permiso de instalación denegado";
      debugPrint(_status);
    }
  }
}
