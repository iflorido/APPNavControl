import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'; 
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const NavControlApp());
}

// --- CONFIGURACIÓN DEL SERVICIO (IGUAL) ---
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'navcontrol_tracker', 
    'NavControl Service', 
    description: 'Rastreo de ubicación activo',
    importance: Importance.low, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, 
      isForegroundMode: true,
      notificationChannelId: 'navcontrol_tracker',
      initialNotificationTitle: 'NavControl',
      initialNotificationContent: 'Servicio iniciado...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// --- LÓGICA EN SEGUNDO PLANO (IGUAL) ---
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  final prefs = await SharedPreferences.getInstance();
  final String? apiUrl = prefs.getString('api_url');
  final String? token = prefs.getString('api_token');
  final int? internalId = prefs.getInt('vehiculo_internal_id');
  
  int refreshRate = prefs.getInt('refresh_rate') ?? 30;
  if (refreshRate < 5) refreshRate = 5;

  debugPrint("🚀 Servicio iniciado. Frecuencia: $refreshRate seg.");
  
  service.invoke('update', {
    "status": "loading", 
    "msg": "Servicio arrancado. Esperando GPS...",
    "last_update": DateTime.now().toIso8601String(),
    "bat": 0,
  });
  
  service.invoke('log', {"msg": "🚀 Servicio iniciado (Cada ${refreshRate}s)"});
  
  Position? lastPosition;
  DateTime? lastTime;

  const LocationSettings locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 0, 
  );

  Timer.periodic(Duration(seconds: refreshRate), (timer) async {
    if (apiUrl == null || token == null || internalId == null) {
      service.invoke('log', {"msg": "❌ Falta configuración (URL/Token)"});
      return; 
    }

    int batteryLevel = 0;
    try {
       batteryLevel = await Battery().batteryLevel;
    } catch(e) { batteryLevel = -1; }

    try {
      service.invoke('log', {"msg": "🛰️ Obteniendo GPS..."});
      
      Position position = await Geolocator.getCurrentPosition(locationSettings: locationSettings);
      
      double velocidadFinal = 0.0;
      
      if (position.speed > 0.5) { 
        velocidadFinal = position.speed * 3.6; 
      } 
      else if (lastPosition != null && lastTime != null) {
        double distMetros = Geolocator.distanceBetween(
          lastPosition!.latitude, lastPosition!.longitude, 
          position.latitude, position.longitude
        );
        
        int timeDiff = DateTime.now().difference(lastTime!).inSeconds;
        
        if (timeDiff > 0) {
          double velocidadCalc = (distMetros / timeDiff) * 3.6;
          if (velocidadCalc > 1 && velocidadCalc < 200) {
              velocidadFinal = velocidadCalc;
          }
        }
      }

      lastPosition = position;
      lastTime = DateTime.now();

      service.invoke('log', {"msg": "📡 Enviando datos (Vel: ${velocidadFinal.toInt()} km/h)..."});

      final respHist = await http.post(
        Uri.parse('$apiUrl/historial/'),
        headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
        body: json.encode({
          "vehiculo": internalId,
          "latitud": position.latitude,
          "longitud": position.longitude,
          "velocidad": velocidadFinal.toInt(), 
          "bateria": batteryLevel
        }),
      );

      await http.patch(
         Uri.parse('$apiUrl/flota/$internalId/'),
         headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
         body: json.encode({ "ultima_posicion": {"type": "Point", "coordinates": [position.longitude, position.latitude]} })
      );

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "NavControl: Conectado 🟢",
          content: "Vel: ${velocidadFinal.toInt()} km/h | Bat: $batteryLevel%",
        );
      }

      service.invoke('update', {
        "status": "ok", 
        "msg": "Conectado",
        "last_update": DateTime.now().toIso8601String(),
        "bat": batteryLevel,
      });

      service.invoke('log', {"msg": "✅ Datos enviados (HTTP ${respHist.statusCode})"});

    } catch (e) {
      debugPrint("❌ [Background] Error: $e");

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "NavControl: Sin Conexión 🔴",
          content: "Intentando reconectar...",
        );
      }

      service.invoke('update', {
        "status": "error", 
        "msg": "Error de conexión",
        "last_update": DateTime.now().toIso8601String(),
        "bat": batteryLevel,
      });
      
      service.invoke('log', {"msg": "❌ Error: $e"});
    }
  });
}

// --- INTERFAZ UI ---
class NavControlApp extends StatelessWidget {
  const NavControlApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NavControl Driver',
      debugShowCheckedModeBanner: false, 
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF2F2F7), 
        primarySwatch: Colors.blue,
        useMaterial3: true,
        fontFamily: Platform.isIOS ? '.SF Pro Text' : null,
        // CORRECCIÓN 1: Eliminado 'cardTheme' global conflictivo. 
        // Usaremos estilo manual en _buildIOSCard.
      ),
      home: const SplashScreen(),
    );
  }
}

// Pantalla de Carga
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}
class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkPermissionsAndSession();
  }

  Future<void> _checkPermissionsAndSession() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    final prefs = await SharedPreferences.getInstance();
    final hasConfig = prefs.containsKey('vehiculo_internal_id');
    
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => hasConfig ? const DashboardScreen() : const ConfigScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: CupertinoActivityIndicator(radius: 20)) 
    );
  }
}

// Pantalla Configuración
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});
  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _apiUrlCtrl = TextEditingController(text: "https://navcontrol.automaworks.es/api");
  final _tokenCtrl = TextEditingController(text: "e588558833e4365f809cb273a587e962b054c9e7");
  final _idCtrl = TextEditingController();
  bool _isLoading = false;

  Future<void> _saveAndConnect() async {
    setState(() => _isLoading = true);
    try {
      final urlVehiculo = '${_apiUrlCtrl.text}/flota/?identificador=${_idCtrl.text}';
      final response = await http.get(Uri.parse(urlVehiculo), headers: {
        "Content-Type": "application/json", "Authorization": "Token ${_tokenCtrl.text}"
      });

      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(utf8.decode(response.bodyBytes));
        if (results.isNotEmpty) {
          final data = results[0];
          
          int tiempoRefresco = 30; 
          try {
            final urlConfig = '${_apiUrlCtrl.text}/configuracion/';
            final respConfig = await http.get(Uri.parse(urlConfig), headers: {
              "Content-Type": "application/json", "Authorization": "Token ${_tokenCtrl.text}"
            });
            if (respConfig.statusCode == 200) {
              final List<dynamic> configResults = json.decode(utf8.decode(respConfig.bodyBytes));
              if (configResults.isNotEmpty) {
                tiempoRefresco = configResults[0]['tiempo_refresco'];
              }
            }
          } catch (e) { }

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('api_url', _apiUrlCtrl.text);
          await prefs.setString('api_token', _tokenCtrl.text);
          await prefs.setString('vehiculo_identifier', _idCtrl.text);
          await prefs.setInt('vehiculo_internal_id', data['id']);
          await prefs.setString('vehiculo_nombre', data['nombre']);
          await prefs.setString('vehiculo_matricula', data['matricula']);
          await prefs.setInt('refresh_rate', tiempoRefresco);

          final service = FlutterBackgroundService();
          await service.startService();

          if (mounted) {
            Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DashboardScreen()));
          }
        } else {
          _showSnack("ID no encontrado");
        }
      } else {
        _showSnack("Error API: ${response.statusCode}");
      }
    } catch (e) {
      _showSnack("Error conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text("Configuración"), backgroundColor: Colors.white, elevation: 0),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const Icon(Icons.settings_remote, size: 80, color: Color(0xFF007AFF)), 
              const SizedBox(height: 20),
              _buildIOSInput(_apiUrlCtrl, "URL API", false),
              const SizedBox(height: 15),
              _buildIOSInput(_tokenCtrl, "Token", true),
              const SizedBox(height: 15),
              _buildIOSInput(_idCtrl, "ID Dispositivo", false),
              const SizedBox(height: 30),
              _isLoading 
                ? const CupertinoActivityIndicator() 
                : SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _saveAndConnect, 
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF007AFF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                      ),
                      child: const Text("Guardar y Conectar", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))
                    ),
                  )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIOSInput(TextEditingController ctrl, String label, bool obscure) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF2F2F7),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}

// Pantalla Principal (Dashboard)
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _nombre = "...";
  String _matricula = "...";
  
  // MANTENIMIENTO
  String _mantenimientoText = "Verificando...";
  // CORRECCIÓN 2: Eliminado _mantenimientoColor porque no se usaba (fondo siempre blanco)
  Color _mantenimientoIconColor = Colors.grey;
  IconData _mantenimientoIcon = Icons.build_circle;
  bool _hasAlerts = false; 

  // ESTADO
  String _statusText = "Iniciando servicio..."; 
  // CORRECCIÓN 3: Eliminado _statusColor porque no se usaba
  Color _iconColor = Colors.orange;
  IconData _statusIcon = Icons.sync;
  
  // LOGS
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLocalData();
    _checkVehicleHealth();
    _listenToService();
  }

  Future<void> _checkVehicleHealth() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_url');
    final token = prefs.getString('api_token');
    final id = prefs.getInt('vehiculo_internal_id');

    if (url == null || token == null || id == null) return;

    try {
      final response = await http.get(
        Uri.parse('$url/flota/$id/'),
        headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
      );

      if (response.statusCode == 200) {
        final bodyString = utf8.decode(response.bodyBytes);
        final data = json.decode(bodyString);
        
        double kmActual = 0.0;
        if (data['kilometraje_total'] != null) {
          kmActual = (data['kilometraje_total'] is int) 
              ? (data['kilometraje_total'] as int).toDouble() 
              : (data['kilometraje_total'] as double);
        }

        int kmRevision = data['km_proxima_revision'] ?? 15000;
        String? fechaItvStr = data['fecha_itv']; 
        
        List<String> alertas = [];
        bool esCritico = false;

        double kmRestantes = kmRevision - kmActual;
        
        if (kmRestantes <= 0) {
          alertas.add("⚠️ Revisión de Km VENCIDA");
          esCritico = true;
        } else if (kmRestantes < 2000) {
          alertas.add("⚠️ Revisión en ${kmRestantes.toInt()} km");
        }

        if (fechaItvStr != null && fechaItvStr != "") {
          DateTime itv = DateTime.parse(fechaItvStr);
          DateTime hoy = DateTime.now();
          DateTime hoySoloFecha = DateTime(hoy.year, hoy.month, hoy.day);
          DateTime itvSoloFecha = DateTime(itv.year, itv.month, itv.day);
          
          int diasRestantes = itvSoloFecha.difference(hoySoloFecha).inDays;

          if (diasRestantes < 0) {
            alertas.add("⛔ ITV CADUCADA");
            esCritico = true;
          } else if (diasRestantes <= 30) {
            alertas.add("📅 ITV caduca en $diasRestantes días");
          }
        }

        if (mounted) {
          setState(() {
            if (alertas.isEmpty) {
              _mantenimientoText = "Todo en orden";
              _mantenimientoIconColor = const Color(0xFF34C759); 
              _mantenimientoIcon = Icons.verified;
              _hasAlerts = false;
            } else {
              _mantenimientoText = alertas.join("\n");
              _hasAlerts = true;
              if (esCritico) {
                _mantenimientoIconColor = const Color(0xFFFF3B30); 
                _mantenimientoIcon = Icons.error;
              } else {
                _mantenimientoIconColor = const Color(0xFFFF9500); 
                _mantenimientoIcon = Icons.warning_amber_rounded;
              }
            }
          });
        }
      }
    } catch (e) {
      debugPrint("❌ Error checking health: $e");
    }
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nombre = prefs.getString('vehiculo_nombre') ?? "-";
      _matricula = prefs.getString('vehiculo_matricula') ?? "-";
    });
  }

  void _listenToService() {
    final service = FlutterBackgroundService();
    
    service.on('update').listen((event) {
      if (event != null && mounted) {
        setState(() {
          String time = "";
          try {
            time = event['last_update'].toString().split('T')[1].split('.')[0].substring(0, 5);
          } catch (e) { time = "--:--"; }
          
          String msg = event['msg'] ?? "";

          if (event['status'] == 'error') {
            _iconColor = const Color(0xFFFF3B30);
            _statusIcon = Icons.wifi_off;
            _statusText = "Sin conexión\n$msg";
          } else if (event['status'] == 'loading') {
            _iconColor = const Color(0xFFFF9500);
            _statusIcon = Icons.sync;
            _statusText = "Conectando...\n$msg";
          } else {
            _iconColor = const Color(0xFF34C759); 
            _statusIcon = Icons.check_circle;
            _statusText = "En línea\nActualizado: $time";
          }
        });
      }
    });

    service.on('log').listen((event) {
      if (event != null && mounted) {
        setState(() {
          String time = DateTime.now().toString().split(' ')[1].split('.')[0];
          _logs.insert(0, "[$time] ${event['msg']}");
          if (_logs.length > 50) _logs.removeLast();
        });
      }
    });
  }

  Future<void> _verifyAndStop(String inputCode) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CupertinoActivityIndicator()),
    );

    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_url');
    final token = prefs.getString('api_token');
    final id = prefs.getInt('vehiculo_internal_id');

    if (mounted) Navigator.pop(context);

    if (url == null || token == null || id == null) {
      _showSnack("Error de sesión interna.", Colors.red);
      return;
    }

    try {
      _addLogToUI("Verificando código con servidor...");
      
      final response = await http.get(
        Uri.parse('$url/flota/$id/'),
        headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final serverCode = data['codigo_seguridad']?.toString() ?? "0000";

        if (inputCode == serverCode) {
          _addLogToUI("Código correcto. Deteniendo...");
          if (mounted) Navigator.pop(context); 
          await _stopServiceAndLogout(); 
        } else {
          _showSnack("Código Incorrecto.", Colors.red);
          _addLogToUI("Intento fallido de código.");
        }
      } else {
        _showSnack("Error servidor: ${response.statusCode}", Colors.orange);
      }
    } catch (e) {
      _showSnack("Error de conexión", Colors.red);
      _addLogToUI("Error verificando: $e");
    }
  }

  void _addLogToUI(String msg) {
    if (mounted) {
       setState(() {
          String time = DateTime.now().toString().split(' ')[1].split('.')[0];
          _logs.insert(0, "[$time] UI: $msg");
       });
    }
  }

  Future<void> _sendClosingAlert() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_url');
    final token = prefs.getString('api_token');
    final id = prefs.getInt('vehiculo_internal_id');

    if (url != null && token != null && id != null) {
      try {
        await http.post(
          Uri.parse('$url/avisos/'),
          headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
          body: json.encode({
            "vehiculo": id,
            "tipo": "DESCONEXION",
            "mensaje": "⚠️ ALERTA: App cerrada manualmente con código.",
            "leido": false
          }),
        );
      } catch (e) { /* silent */ }
    }
  }

  Future<void> _stopServiceAndLogout() async {
    showDialog(
      context: context, 
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CupertinoActivityIndicator())
    );

    await _sendClosingAlert();
    final service = FlutterBackgroundService();
    service.invoke("stopService"); 
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    if (mounted) {
      Navigator.pop(context); 
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ConfigScreen()));
    }
  }

  void _tryDisableTracking(bool value) {
    if (!value) {
      final codeCtrl = TextEditingController();
      showDialog(context: context, builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Seguridad"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Introduce el código para detener."),
            const SizedBox(height: 15),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.text, 
              textCapitalization: TextCapitalization.characters, 
              obscureText: true,
              decoration: InputDecoration(
                hintText: "Código", 
                filled: true,
                fillColor: const Color(0xFFF2F2F7),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar", style: TextStyle(color: Colors.grey))),
          TextButton(
            onPressed: () => _verifyAndStop(codeCtrl.text),
            child: const Text("Apagar", style: TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.bold)),
          )
        ],
      ));
    }
  }

  void _showSnack(String msg, Color color) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // === CAPA 1: CONTENIDO PRINCIPAL ===
          SafeArea(
            child: Column(
              children: [
                // 1. HEADER (Logo y Nombre)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                  child: Row(
                    children: [
                      // LOGO APP 
                      Container(
                        width: 45, height: 45,
                        decoration: BoxDecoration(
                          color: Colors.blueAccent,
                          borderRadius: BorderRadius.circular(12),
                          // CORRECCIÓN 4: withOpacity -> withValues
                          boxShadow: [BoxShadow(color: Colors.blue.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))]
                        ),
                        child: const Icon(Icons.navigation, color: Colors.white), 
                      ),
                      const SizedBox(width: 15),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text("NavControl", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                          Text("Driver Assistant", style: TextStyle(fontSize: 14, color: Colors.grey)),
                        ],
                      )
                    ],
                  ),
                ),

                // 2. CONTENIDO SCROLLABLE (Tarjetas)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        // TARJETA DE VEHÍCULO
                        _buildIOSCard(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(color: const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(15)),
                                    child: const Icon(Icons.directions_car_filled, color: Color(0xFF007AFF), size: 32),
                                  ),
                                  const SizedBox(width: 15),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(_nombre, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(6)),
                                          child: Text(_matricula, style: TextStyle(fontSize: 13, color: Colors.grey[800], fontWeight: FontWeight.w600, letterSpacing: 1)),
                                        )
                                      ],
                                    ),
                                  )
                                ],
                              ),
                            ],
                          )
                        ),
                        const SizedBox(height: 15),

                        // FILA DOBLE: ESTADO Y MANTENIMIENTO
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildIOSCard(
                                padding: 15,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(_statusIcon, color: _iconColor, size: 28),
                                    const SizedBox(height: 10),
                                    Text("Conexión", style: TextStyle(fontSize: 13, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    Text(_statusText, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2)),
                                  ],
                                )
                              ),
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: _buildIOSCard(
                                padding: 15,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Icon(_mantenimientoIcon, color: _mantenimientoIconColor, size: 28),
                                        if (_hasAlerts) 
                                          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFFF3B30), shape: BoxShape.circle))
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Text("Salud", style: TextStyle(fontSize: 13, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    Text(_mantenimientoText, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2), maxLines: 4, overflow: TextOverflow.ellipsis),
                                  ],
                                )
                              ),
                            ),
                          ],
                        ),
                        
                        const SizedBox(height: 15),

                        // BOTÓN DE RASTREO
                        _buildIOSCard(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: const [
                                  Text("Rastreo GPS", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                  Text("Activo en segundo plano", style: TextStyle(fontSize: 13, color: Colors.grey)),
                                ],
                              ),
                              Transform.scale(
                                scale: 0.9,
                                child: CupertinoSwitch(
                                  value: true, 
                                  onChanged: _tryDisableTracking,
                                  activeColor: const Color(0xFF34C759),
                                ),
                              )
                            ],
                          )
                        ),
                        const SizedBox(height: 100), 
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // === CAPA 2: PANEL DESLIZABLE DE LOGS ===
          DraggableScrollableSheet(
            initialChildSize: 0.08,
            minChildSize: 0.08,
            maxChildSize: 0.6,
            builder: (BuildContext context, ScrollController scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                  // CORRECCIÓN 4: withOpacity -> withValues
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20, offset: const Offset(0, -5))
                  ]
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 40, height: 5,
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)),
                    ),
                    const SizedBox(height: 15),
                    
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          const Icon(Icons.terminal, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text("Diagnóstico en tiempo real", style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    Expanded(
                      child: Container(
                        color: const Color(0xFF1C1C1E), 
                        child: ListView.builder(
                          controller: scrollController, 
                          padding: const EdgeInsets.all(15),
                          itemCount: _logs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                _logs[index],
                                style: const TextStyle(color: Color(0xFF34C759), fontFamily: 'Courier', fontSize: 12),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIOSCard({required Widget child, double padding = 20}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        // CORRECCIÓN 4: withOpacity -> withValues
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 15, offset: const Offset(0, 5)),
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 3, offset: const Offset(0, 1)),
        ]
      ),
      child: child,
    );
  }
}