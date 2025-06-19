import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:ui";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:package_info_plus/package_info_plus.dart";
import "package:path_provider/path_provider.dart";
import "package:permission_handler/permission_handler.dart";
import "package:flutter_downloader/flutter_downloader.dart";
import "package:open_filex/open_filex.dart";

@pragma("vm:entry-point")
void downloadCallback(String id, int status, int progress) {
  final SendPort? send = IsolateNameServer.lookupPortByName(
    "downloader_send_port",
  );
  if (send != null) {
    send.send([id, status, progress]);
  }
}

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  UpdateScreenState createState() => UpdateScreenState();
}

class UpdateScreenState extends State<UpdateScreen> {
  final _eventController = StreamController<Map>.broadcast();
  Stream<Map> get eventStream => _eventController.stream;

  void emitEvent(Map event) {
    _eventController.add(event);
  }

  @override
  void dispose() {
    _eventController.close();
    super.dispose();
  }

  String _status = "Verificando actualizaciones...";
  String globalApkUrl = "";

  Future<void> checkForUpdates() async {
    try {
      // Obtener la versión actual de la app
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;

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
        if (latestVersion != currentVersion) {
          emitEvent({
            "show_update_dialog": {
              "apkUrl": apkUrl,
              "latestVersion": latestVersion,
              "forceUpdate": forceUpdate,
            },
          });
        } else {
          _status = "App actualizada (versión $currentVersion)";
          debugPrint(_status);
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

  Future<void> downloadAndInstallApk() async {
    var apkUrl = globalApkUrl;
    // Solicitar permisos de almacenamiento
    var storagePermission = await Permission.manageExternalStorage.request();
    if (storagePermission.isGranted) {
      _status = "Descargando actualización...";
      debugPrint(_status);

      // Obtener el directorio de descargas
      final directory = await getExternalStorageDirectory();
      final savedDir = directory!.path;
      final filePath = "$savedDir/app-release.apk";

      // Descargar el APK
      var donwload = await FlutterDownloader.enqueue(
        url: apkUrl,
        savedDir: savedDir,
        fileName: "app-release.apk",
        showNotification: true,
        openFileFromNotification: true,
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; FlutterDownloader/1.0)',
          'Accept': 'application/vnd.android.package-archive',
        },
      );
      if (donwload!.isNotEmpty) {
        _installApk(filePath);
      }
    } else {
      _status = "Permisos de almacenamiento denegados";
      debugPrint(_status);
    }
  }

  Future<void> downloadAndInstallApkHTTP() async {
    var apkUrl = globalApkUrl;
    // Solicitar permisos de almacenamiento
    var storagePermission = await Permission.manageExternalStorage.request();
    if (storagePermission.isGranted) {
      _status = "Descargando actualización...";

      try {
        final url = Uri.parse(apkUrl);
        final response = await http.get(
          url,
          headers: {
            'User-Agent': 'Mozilla/5.0 (compatible; FlutterDownloader/1.0)',
            'Accept': 'application/vnd.android.package-archive',
          },
        );
        debugPrint("${url}");

        if (response.statusCode == 200) {
          // Obtener el directorio de descargas
          final directory = await getExternalStorageDirectory();
          final savedDir = directory!.path;
          final file = File("$savedDir/app-release.apk");
          await file.writeAsBytes(response.bodyBytes);
          if (await file.exists()) {
            _installApk(file.path);
          }
        }
      } catch (e) {
        _status = "Error al descargar la actualización";
        debugPrint(_status);
      }
    } else {
      _status = "Permisos de almacenamiento denegados";
      debugPrint(_status);
    }
  }

  Future<void> _installApk(String filePath) async {
    // Solicitar permiso para instalar apps
    if (await Permission.requestInstallPackages.request().isGranted) {
      final result = await OpenFilex.open(filePath);
      _status = "Instalación iniciada: ${result.message}";
      debugPrint(_status);
    } else {
      _status = "Permiso de instalación denegado";
      debugPrint(_status);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Actualización OTA")),
      body: Center(child: Text(_status)),
    );
  }
}
