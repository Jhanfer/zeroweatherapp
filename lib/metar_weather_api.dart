import 'package:csv/csv.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';

class Station {
  final String code;
  final double latitude;
  final double longitude;
  final String name;
  final String continent;

  Station({
    required this.code,
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.continent,
  });
}

class WeatherService with ChangeNotifier {
  List<Station> _stations = [];
  Station? _currentStation;
  List<Station> _nearbyStations = [];
  final Map<String, String> isoCountryToContinent = {
    // Norteamérica
    "US": "NA",
    "MX": "NA",
    "CA": "NA",
    "GT": "NA",
    "CU": "NA",
    "CR": "NA",

    // Sudamérica
    "BR": "SA",
    "AR": "SA",
    "CL": "SA",
    "CO": "SA",
    "PE": "SA",
    "UY": "SA",

    // Europa
    "ES": "EU",
    "FR": "EU",
    "DE": "EU",
    "IT": "EU",
    "NL": "EU",
    "PT": "EU",
    "RU": "EU", // Rusia principalmente en Europa
  };

  final _cloudDescriptionPoints = {
    0: {"despejado": Icons.wb_sunny},
    15: {"mayormente despejado": Icons.wb_sunny},
    40: {"parcialmente nublado": Icons.wb_cloudy},
    65: {"mayormente nublado": Icons.cloud},
    85: {"muy nublado": Icons.cloud_queue},
    100: {"completamente nublado": Icons.cloud},
  };
  var cloudDescription = {};
  var appPermission = true;
  Map<String, dynamic>? metarCacheData = {};
  Map<String, dynamic>? forecastCachedData = {};

  var siteName = "";
  var country = "";
  var _currentPosition = {};
  var _lastPosition = {};

  Future<void> loadStation() async {
    try {
      //cargar los datos de las estaciones
      final csvString = await rootBundle.loadString("assets/stations.csv");

      //convertimos el csv a un listado de estaciones y le indicamos a "CsvToListConverter" que el separador es la coma ","
      List<List<dynamic>> rows = const CsvToListConverter(
        eol: "\n",
      ).convert(csvString);
      //creamos un listado de estaciones, donde cada estación que encaje en el "RegExp" (literalmente 4 letras mayusculas) se convierte a una estación parseando con map y las demás columnas usando "row[indicador]".
      _stations = rows
          .skip(1)
          .where(
            (row) => RegExp(
              r'^[A-Z]{4}$',
            ).hasMatch(row[0].toString().trim().toUpperCase()),
          )
          .map(
            (row) => Station(
              code: row[0].toString(),
              latitude: row[1] ?? 0.0,
              longitude: row[2] ?? 0.0,
              name: row[3].toString(),
              continent: row[4].toString(),
            ),
          )
          .toList();
    } catch (e) {
      debugPrint("$e");
    }
  }

  Future<void> updateSiteName() async {
    String safeSiteName = "Ubicación desconocida.";
    String currentCountry = "";
    try {
      if (_currentPosition["latitude"] != null &&
          _currentPosition["longitude"] != null) {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          _currentPosition["latitude"],
          _currentPosition["longitude"],
        );

        if (placemarks.isNotEmpty) {
          safeSiteName =
              placemarks.first.locality ??
              placemarks.first.subLocality ??
              placemarks.first.street ??
              "Ubicación desconocida.";
          currentCountry = placemarks.first.isoCountryCode.toString();
        }
      } else if (_lastPosition["latitude"] != null &&
          _lastPosition["longitude"] != null) {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          _lastPosition["latitude"],
          _lastPosition["longitude"],
        );
        if (placemarks.isNotEmpty) {
          safeSiteName =
              placemarks.first.locality ??
              placemarks.first.subLocality ??
              placemarks.first.street ??
              "Ubicación desconocida.";
          currentCountry = placemarks.first.isoCountryCode.toString();
        }
      }

      siteName = safeSiteName.toString();

      country = currentCountry;
    } catch (e) {
      debugPrint("Error al obtener el nombre de localidad: $e");
    }
  }

  Future<void> getPrecisePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? currentPosition;

    debugPrint("GetPrecisePosition Iniciada.");
    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;

        if (DateTime.now().millisecondsSinceEpoch - timeStamp < 2 * 60 * 1000) {
          debugPrint("Usando posición mejorada cacheada.");
          currentPosition = decodedPositionCache;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }

      if (currentPosition == null) {
        var newPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        );
        currentPosition = {
          "latitude": newPosition.latitude,
          "longitude": newPosition.longitude,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
        };
        final success = await prefs.setString(
          cacheKey,
          json.encode(currentPosition),
        );
        debugPrint("¿Guardado posición en caché?: $success");
      }

      _currentPosition = currentPosition;
      await updateSiteName();

      debugPrint(
        "${_currentPosition["latitude"]}, ${_currentPosition["longitude"]}",
      );
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }

    notifyListeners();
  }

  Future<void> getPosition() async {
    debugPrint("New GetPosition Iniciada.");
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? freshPositionData;

    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;
        // Siempre asignamos la última posición cargada del caché a _lastKnownPosition
        _lastPosition = decodedPositionCache;

        if (DateTime.now().millisecondsSinceEpoch - timeStamp <
            30 * 60 * 1000) {
          debugPrint("CachedPosition");
          freshPositionData = decodedPositionCache;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }

      if (freshPositionData == null) {
        var newPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
        );
        freshPositionData = {
          "latitude": newPosition.latitude,
          "longitude": newPosition.longitude,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
        };
        final success = await prefs.setString(
          cacheKey,
          json.encode(freshPositionData),
        );
        debugPrint("¿Guardado posición en caché?: $success");
      }

      // Si se obtuvo una nueva posición, también actualizamos _lastKnownPosition
      _lastPosition = freshPositionData;
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }
    if (freshPositionData != null) {
      _currentPosition = freshPositionData;

      var lat = _currentPosition["latitude"] ?? _lastPosition["latitude"];
      var long = _currentPosition["longitude"] ?? _lastPosition["longitude"];

      debugPrint("Usando currentPosition: $lat, $long");
    }
    await updateSiteName();
    notifyListeners();
  }

  //Encontrar la estación más cercana
  findNerbyStation() {
    debugPrint("Iniciando búsqueda de estación cercana.");
    if (_stations.isEmpty) {
      debugPrint("No hay estaciones disponibles.");
      _nearbyStations = [];
      notifyListeners();
      return;
    }
    // Ordenar estaciones por distancia
    List<Map<String, dynamic>> stationsWithDistance = _stations.map((station) {
      double distance = Geolocator.distanceBetween(
        _currentPosition["latitude"] ?? 0.0,
        _currentPosition["longitude"] ?? 0.0,
        station.latitude,
        station.longitude,
      );
      return {'station': station, 'distance': distance};
    }).toList();

    // Ordenar por distancia ascendente
    stationsWithDistance.sort((a, b) => a["distance"].compareTo(b["distance"]));

    // Tomar las 3 estaciones más cercanas (o menos si no hay suficientes)
    _nearbyStations = stationsWithDistance
        .take(3)
        .map<Station>((entry) => entry["station"] as Station)
        .toList();

    // Establecer la estación más cercana como _currentStation
    _currentStation = _nearbyStations.isNotEmpty ? _nearbyStations.first : null;
    debugPrint(
      "Estaciones cercanas encontradas: ${_nearbyStations.map((s) => s.code).join(', ')}",
    );
    notifyListeners();
  }

  hasMovedSignificantly() {
    // Extraer las latitudes y longitudes de los mapas
    final double currentLat = _currentPosition["latitude"] as double;
    final double currentLon = _currentPosition["longitude"] as double;
    final double lastLat = _lastPosition["latitude"] as double;
    final double lastLon = _lastPosition["longitude"] as double;

    // Calcular la distancia en metros usando geolocator
    final double distanceInMeters = Geolocator.distanceBetween(
      currentLat,
      currentLon,
      lastLat,
      lastLon,
    );
    // Convertir el umbral de kilómetros a metros para la comparación
    var thresholdKM = 0.5;
    final double thresholdMeters = thresholdKM * 1000;

    return distanceInMeters >= thresholdMeters;
  }

  //API para procesar datos METAR y combinar con NOAA
  Future<void> fetchMetarData() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_$_currentStation";
    final cachedData = prefs.getString(cacheKey);
    http.Response? metarResponse;
    http.Response? meteoResponse;
    Map<String, dynamic>? dataToUse;

    //Verificar si hay datos en la memoria caché
    if (cachedData != null) {
      final data = jsonDecode(cachedData);
      final timeStamp = data["timeStamp"] ?? 0;

      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 30 * 60 * 1000) {
        debugPrint("CachedData");
        //Si el tiempo de cache es menor a 30 minutos, usar datos de la memoria caché, de lo contrario, rescatar nueva info
        dataToUse = data;
      }
    }

    if (dataToUse == null || hasMovedSignificantly()) {
      // Descargar los datos METAR
      try {
        if (country.isNotEmpty) {
          if (country == "ES" || country == "Spain") {
            metarResponse = await http.get(
              Uri.parse(
                "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${_currentStation!.code}.TXT",
              ),
            );
          } else {
            metarResponse = await http.get(
              Uri.parse(
                "https://aviationweather.gov/api/data/metar?ids=${_currentStation!.code}&format=raw",
              ),
              headers: {
                'User-Agent':
                    'TuApp/1.0 (zeroweather.app.api)', // Requerido para APIs de NWS
              },
            );
          }

          if (metarResponse.statusCode != 200 ||
              metarResponse.body.isEmpty == true) {
            for (var station in _nearbyStations) {
              metarResponse = await http.get(
                Uri.parse(
                  "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${station.code}.TXT",
                ),
              );
              if (metarResponse.statusCode == 200) {
                debugPrint("estación que funciona ${station.code}");
                _currentStation = station;
                break;
              }
            }
          }

          meteoResponse = await http.get(
            Uri.parse(
              "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&current=is_day,precipitation,showers,snowfall,wind_gusts_10m,pressure_msl,cloud_cover,weather_code",
            ),
          );
        }
      } catch (e) {
        debugPrint("$e");
      }

      if (metarResponse?.statusCode == 200 &&
          meteoResponse?.statusCode == 200) {
        debugPrint("OnlineData");

        final lines = metarResponse?.body.split("\n");
        debugPrint("$lines");
        //Datos de api externa
        final externalData = jsonDecode(meteoResponse!.body);
        String? temp, dewPoint, pressure, condition;
        DateTime? dateTime;
        double? windKmh, widDirection;

        for (var line in lines!) {
          final parts = line.trim().split(" ");
          for (var part in parts) {
            if (part.length == 7 && part.endsWith("Z")) {
              int day = int.parse(part.substring(0, 2));
              int hour = int.parse(part.substring(2, 4));
              int minute = int.parse(part.substring(4, 6));
              final now = DateTime.now();
              dateTime = DateTime.parse(
                "${now.year}-${now.month.toString().padLeft(2, "0")}-$day ${hour.toString().padLeft(2, "0")}:${minute.toString().padLeft(2, "0")}:00",
              ).toUtc();
            }

            if (part.contains("/")) {
              final tempDewRegex = RegExp(r"^M?\d{2}/M?\d{2}$");
              // "^" y "$" aseguran que todos los digitos encajen. "M?\d{2}" significa que puede haber un "M" opcional seguido de 2 digitos. "/" una barra normal. "M?\d{2}" lo mismo que antes.
              if (tempDewRegex.hasMatch(part)) {
                final tempDew = part.split("/");
                //Temperatura
                var initialTemp = tempDew[0].replaceFirst("M", "-");
                var normalizedTemp =
                    (int.parse(initialTemp) * 0.4) +
                    (forecastCachedData!["tempByHours"][0] * 0.6);

                temp = normalizedTemp.toString();

                //Punto de rocío
                dewPoint = tempDew[1].replaceFirst("M", "-");
              }
            }
            if (part.contains("KT")) {
              var windSpeed = part; //Viento

              var direction = RegExp(r'^(\d{3})').firstMatch(windSpeed);

              if (direction != null) {
                widDirection = double.parse(direction.group(1)!);
              }

              final speedMatch = RegExp(
                r'(\d{2,3})(?:G\d{2,3})?KT$',
              ).firstMatch(windSpeed);
              if (speedMatch != null) {
                final speedKt = int.parse(speedMatch.group(1)!);
                if (speedKt >= 0 && speedKt <= 100) {
                  // Validar rango razonable
                  final speedKmh = speedKt * 1.852;
                  windKmh = speedKmh; // Ej. 16.7 km/h
                } else {
                  windKmh = 0.0; // Velocidad fuera de rango
                }
              } else {
                windKmh = 0.0; // No se pudo extraer velocidad
              }
            }
            if (part.startsWith("Q") ||
                part.startsWith("A") && part.length == 5) {
              final pressureString = part.substring(1); //eliminar Q o A
              if (part.startsWith("Q")) {
                pressure = pressureString;
              } else {
                final intValue = int.tryParse(pressureString);
                if (intValue != null) {
                  double pressureDouble = intValue / 100;
                  const double conversionFactor = 33.86388666667;
                  pressure = (pressureDouble * conversionFactor)
                      .toStringAsFixed(2);
                }
              }
            }
            if (["CLR", "FEW", "SCT", "BKN", "OVC"].contains(part)) {
              condition = part; //Condición
            }
          }
        }

        if (temp != null && dewPoint != null) {
          double tempC = double.parse(temp);
          double dewPointC = double.parse(dewPoint);
          double? heatIndex;

          //Calcular humedad
          var vaporDewPressure =
              6.112 * exp((17.625 * dewPointC) / (dewPointC + 243.04));
          var vaporTempPressure =
              6.112 * exp((17.625 * tempC) / (tempC + 243.04));
          double humidity = 100 * (vaporDewPressure / vaporTempPressure);

          //Calcular sensación térmica
          if (tempC < 10.0 && windKmh != null && windKmh > 4.8) {
            final v = pow(windKmh, 0.16);
            heatIndex = 13.12 + 0.6215 * tempC - 11.37 * v + 0.3965 * tempC * v;
          } else if (tempC > 27.0 && humidity > 40) {
            // Convertir °C a °F
            final T = tempC * 9 / 5 + 32;
            final rh = humidity;
            // Fórmula NOAA para Heat Index en °F
            final hi =
                -42.379 +
                2.04901523 * T +
                10.14333127 * rh -
                0.22475541 * T * rh -
                6.83783e-3 * T * T -
                5.481717e-2 * rh * rh +
                1.22874e-3 * T * T * rh +
                8.5282e-4 * T * rh * rh -
                1.99e-6 * T * T * rh * rh;

            // Convertir HI de °F a °C
            heatIndex = (hi - 32) * 5 / 9;
          } else {
            heatIndex = tempC;
          }

          dataToUse = {
            "temperature": tempC,
            "dewPoint": dewPointC,
            "humidity": humidity.roundToDouble(),
            "windSpeed": windKmh,
            "widDirection": widDirection,
            "heatIndex": heatIndex.toStringAsFixed(2),
            "pressure": pressure ?? "NA",
            "condition": condition ?? "NA",
            "cloudCover": externalData["current"]["cloud_cover"] / 100 * 100,
            "dateTime": dateTime.toString(),
            "currentPrecipitation": externalData["current"]["precipitation"],
            "currentShowers": externalData["current"]["showers"],
            "currentSnowfall": externalData["current"]["snowfall"],
            "currentWindGusts": externalData["current"]["wind_gusts_10m"],
            "currentSurfacePressure":
                externalData["current"]["surface_pressure"],
            "isDay": externalData["current"]["is_day"],
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
            "weather_code": externalData["current"]["weather_code"],
            "METAR_ICAO": _currentStation!.code,
          };

          debugPrint(_currentStation!.name);

          //Guardar caché
          final success = await prefs.setString(
            cacheKey,
            json.encode(dataToUse),
          );
          debugPrint("¿Guardado el tiempo en caché?: $success");
        } else {
          throw Exception("No se pudo obtener la información del clima");
        }
      }
    }

    //Nubes fuera del try para mejor manejo
    if (dataToUse != null) {
      for (var point in _cloudDescriptionPoints.entries) {
        if (point.key <= dataToUse["cloudCover"]) {
          cloudDescription = point.value;
        }
      }
    }
    metarCacheData = dataToUse;
    notifyListeners();
  }

  Future<void> getForecast() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "meteo_forecast";
    final forecastCached = prefs.getString(cacheKey);
    http.Response? forecastHourlyResponse;
    http.Response? forecastDailyResponse;
    Map<String, dynamic>? dataToUse;

    if (forecastCached != null) {
      final data = jsonDecode(forecastCached);
      final timeStamp = data["timeStamp"] ?? 0;

      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 30 * 60 * 1000) {
        debugPrint("CachedForecastData");
        dataToUse = data;
      }
    }

    if (dataToUse == null || hasMovedSignificantly()) {
      try {
        forecastHourlyResponse = await http.get(
          Uri.parse(
            "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&hourly=temperature_2m,precipitation_probability",
          ),
        );

        forecastDailyResponse = await http.get(
          Uri.parse(
            "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&daily=sunrise,sunset,sunshine_duration,daylight_duration,uv_index_max",
          ),
        );

        if (forecastHourlyResponse.statusCode == 200 &&
            forecastDailyResponse.statusCode == 200) {
          final houtlyData = jsonDecode(forecastHourlyResponse.body);
          final hourlyTemp = houtlyData["hourly"]["temperature_2m"];
          final hourlyTime = houtlyData["hourly"]["time"];
          final hourlyPrecipitationProbability =
              houtlyData["hourly"]["precipitation_probability"];
          List<int> hours = [];
          List<String> dates = [];
          List<double> parsedTemp = [];
          List<double> parsedPrecipitation = [];

          var now = DateTime.now().toLocal();
          final limit = now.add(const Duration(hours: 24));

          for (int i = 0; i < hourlyTime.length; i++) {
            var parsed = DateTime.parse(hourlyTime[i]).toLocal();
            if (parsed.isAfter(now) &&
                parsed.isBefore(limit) &&
                !hours.contains(parsed.hour)) {
              hours.add(parsed.hour);
              dates.add(parsed.toIso8601String());

              parsedTemp.add(hourlyTemp[i].toDouble());
              parsedPrecipitation.add(
                hourlyPrecipitationProbability[i].toDouble(),
              );
            }
          }

          final dailyData = jsonDecode(forecastDailyResponse.body);
          final dailySunrise = dailyData["daily"]["sunrise"];
          final dailySunset = dailyData["daily"]["sunset"];
          final dailySunshineDuration = dailyData["daily"]["sunshine_duration"];
          final dailyDaylightDuration = dailyData["daily"]["daylight_duration"];
          final dailyUVIndexMax = dailyData["daily"]["uv_index_max"];

          var maxTemp = parsedTemp.reduce(
            (currentMax, element) =>
                element > currentMax ? element : currentMax,
          );
          var minTemp = parsedTemp.reduce(
            (currentMin, element) =>
                element < currentMin ? element : currentMin,
          );

          dataToUse = {
            "tempHours": hours,
            "precipitationByHours": parsedPrecipitation,
            "tempByHours": parsedTemp,
            "maxTemp": maxTemp,
            "minTemp": minTemp,
            "dates": dates,
            "dailySunrise": dailySunrise,
            "dailySunset": dailySunset,
            "dailySunshineDuration": dailySunshineDuration,
            "dailyDaylightDuration": dailyDaylightDuration,
            "dailyUVIndexMax": dailyUVIndexMax,
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
          };
        }

        //Guardar caché
        final success = await prefs.setString(cacheKey, json.encode(dataToUse));
        debugPrint("¿Guardado forecast en caché?: $success");
      } catch (e) {
        debugPrint("Se ha presentado un error: $e");
      }
    }
    forecastCachedData = dataToUse;
    notifyListeners();
  }
}
