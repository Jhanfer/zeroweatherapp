import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:zeroweather/metar_weather_api.dart';

class NotificationsService {
  static final NotificationsService _instance =
      NotificationsService._internal();
  static final _notifications = FlutterLocalNotificationsPlugin();

  factory NotificationsService() => _instance;

  NotificationsService._internal();

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      debugPrint("Inicializando notificaciones...");
      final String? currentTimezone = await FlutterTimezone.getLocalTimezone();
      if (currentTimezone == null) {
        debugPrint("Error: No se pudo obtener la zona horaria");
        return;
      }

      tz.initializeTimeZones();
      final location = tz.getLocation(currentTimezone);
      tz.setLocalLocation(location);

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings("@mipmap/ic_launcher");
      const InitializationSettings initializationSettings =
          InitializationSettings(android: androidSettings);

      await _notifications.initialize(initializationSettings);

      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        debugPrint(
          granted == true
              ? "Permiso de notificaciones otorgado"
              : "Permiso de notificaciones no otorgado",
        );
      } else {
        debugPrint("No se pudo obtener el plugin de Android");
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint("Error al inicializar notificaciones: $e");
    }
  }

  Future<void> initBackground() async {
    if (_isInitialized) return;

    try {
      debugPrint("Inicializando notificaciones en segundo plano...");
      final String? currentTimezone = await FlutterTimezone.getLocalTimezone();
      if (currentTimezone == null) {
        debugPrint("Error: No se pudo obtener la zona horaria");
        return;
      }

      tz.initializeTimeZones();
      final location = tz.getLocation(currentTimezone);
      tz.setLocalLocation(location);

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings("@mipmap/ic_launcher");
      const InitializationSettings initializationSettings =
          InitializationSettings(android: androidSettings);

      await _notifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: (response) {
          debugPrint(
            "Notificación recibida en background: ${response.payload}",
          );
        },
      );

      _isInitialized = true;
    } catch (e) {
      debugPrint("Error al inicializar notificaciones en background: $e");
    }
  }

  Future<void> showInstantNotificationBackground() async {
    Map<String, dynamic>? metarData;
    String? cloudCover;
    double? temp;
    String? precipitation;
    int precipitationPriority = 0;
    int cloudPriority = 0;
    try {
      await initBackground();

      try {
        final weatherapi = WeatherService();
        metarData = await weatherapi.fetchDataBackground();
        debugPrint("Datos recibidos: $metarData");

        final androidPlugin = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (androidPlugin == null) {
          debugPrint("Error: No se pudo obtener el plugin de Android");
          return;
        }

        const AndroidNotificationDetails androidDetails =
            AndroidNotificationDetails(
              "instant_channel142",
              "Notificaciones",
              channelDescription: "Canal para notificaciones instantáneas",
              importance: Importance.max,
              priority: Priority.high,
              icon: "zeroweatherlogo",
              largeIcon: DrawableResourceAndroidBitmap("zeroweatherlogo"),
              onlyAlertOnce: true,
            );
        const NotificationDetails notificationDetails = NotificationDetails(
          android: androidDetails,
        );

        if (metarData.isNotEmpty &&
            metarData["temperature"] != null &&
            metarData["cloudCover"] != null &&
            metarData != {}) {
          if (metarData["cloudCover"] <= 0) {
            cloudCover = "Despejado";
            cloudPriority = 0;
          } else if (metarData["cloudCover"] <= 15) {
            cloudCover = "Parcialmente nublado";
            cloudPriority = 1;
          } else if (metarData["cloudCover"] <= 40) {
            cloudCover = "Nublado";
            cloudPriority = 2;
          } else if (metarData["cloudCover"] >= 50) {
            cloudCover = "Muy nublado";
            cloudPriority = 3;
          }

          temp = metarData["temperature"];

          if (metarData["precipitation"] <= 0) {
            precipitation = "No se espera lluvia";
            precipitationPriority = 0;
          } else if (metarData["precipitation"] <= 15) {
            precipitation = "Posibles lluvias";
            precipitationPriority = 1;
          } else if (metarData["precipitation"] <= 40) {
            precipitation = "Es muy probable que llueva";
            precipitationPriority = 2;
          } else if (metarData["precipitation"] >= 50) {
            precipitation = "Lluvias intensas";
            precipitationPriority = 3;
          }
        }

        final String title = "Hoy se esperan temperaturas de $temp";

        String? mensajeFinal;
        if (precipitationPriority >= cloudPriority) {
          mensajeFinal = precipitation;
        } else {
          mensajeFinal = cloudCover;
        }

        await _notifications.show(
          42, // ID de la notificación
          title.toString(),
          mensajeFinal.toString(),
          notificationDetails,
        );
        debugPrint("Notificación instantánea mostrada exitosamente");
      } catch (e) {
        debugPrint("Error al obtener datos: $e");
      }
    } catch (e) {
      debugPrint("Error al mostrar la notificación instantánea: $e");
    }
  }

  Future<void> showInstantNotification() async {
    try {
      if (!_isInitialized) {
        await init();
      }

      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidPlugin == null) {
        debugPrint("Error: No se pudo obtener el plugin de Android");
        return;
      }

      // Verificar permiso de notificaciones
      final notificationsGranted = await androidPlugin
          .requestNotificationsPermission();
      if (notificationsGranted != true) {
        debugPrint("No se pueden mostrar notificaciones: permiso no otorgado");
        return;
      }

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            "instant_channel",
            "Notificaciones",
            channelDescription: "Canal para notificaciones instantáneas",
            importance: Importance.max,
            priority: Priority.high,
          );
      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        0, // ID de la notificación
        "Ivana es city",
        "Quiero decir que Ivana es city",
        notificationDetails,
      );
      debugPrint("Notificación instantánea mostrada exitosamente");
    } catch (e) {
      debugPrint("Error al mostrar la notificación instantánea: $e");
    }
  }

  Future<void> scheduleNotification() async {
    try {
      if (!_isInitialized) {
        await init();
      }

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            "instant_channel",
            "Notificaciones",
            channelDescription: "Canal para notificaciones instantáneas",
            importance: Importance.max,
            priority: Priority.high,
          );
      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.zonedSchedule(
        24,
        "Hola!",
        "Esto es una notificación",
        tz.TZDateTime.now(tz.local).add(Duration(seconds: 1)),
        notificationDetails,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint(
        "Notificación programada exitosamente para ${tz.TZDateTime.now(tz.local).add(Duration(seconds: 1))}",
      );
    } catch (e) {
      debugPrint("Error al programar la notificación: $e");
    }
  }
}
