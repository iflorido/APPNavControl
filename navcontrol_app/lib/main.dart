import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
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

// --- CONFIGURACIÓN DEL SERVICIO ---
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

// --- LÓGICA EN SEGUNDO PLANO ---
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

  // Configuración inicial
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
  
  // Variables de estado para el cálculo de velocidad
  Position? lastPosition;
  DateTime? lastTime;

  // Configuración GPS moderna (Soluciona el warning de deprecated)
  const LocationSettings locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 0, 
  );

  Timer.periodic(Duration(seconds: refreshRate), (timer) async {
    if (apiUrl == null || token == null || internalId == null) {
      service.invoke('log', {"msg": "❌ Falta configuración (URL/Token)"});
      return; 
    }

    // Obtenemos datos del dispositivo (Batería)
    int batteryLevel = 0;
    try {
       batteryLevel = await Battery().batteryLevel;
    } catch(e) { batteryLevel = -1; }

    try {
      // Aviso de log
      service.invoke('log', {"msg": "🛰️ Obteniendo GPS..."});
      
      // 1. OBTENER POSICIÓN (UNA SOLA VEZ)
      // Usamos locationSettings para evitar el warning
      Position position = await Geolocator.getCurrentPosition(locationSettings: locationSettings);
      
      // --- LÓGICA DE VELOCIDAD MEJORADA ---
      double velocidadFinal = 0.0;
      
      // A. Preferimos la velocidad nativa del GPS si el coche se mueve (> 1.8 km/h aprox)
      if (position.speed > 0.5) { 
        velocidadFinal = position.speed * 3.6; // m/s a km/h
      } 
      // B. Si el GPS dice 0 pero hay movimiento real (Fallback)
      else if (lastPosition != null && lastTime != null) {
        double distMetros = Geolocator.distanceBetween(
          lastPosition!.latitude, lastPosition!.longitude, 
          position.latitude, position.longitude
        );
        
        int timeDiff = DateTime.now().difference(lastTime!).inSeconds;
        
        if (timeDiff > 0) {
          double velocidadCalc = (distMetros / timeDiff) * 3.6;
          // Filtro: Solo aceptamos si es realista (> 1 km/h y < 200 km/h)
          // Esto evita saltos locos del GPS estando parado
          if (velocidadCalc > 1 && velocidadCalc < 200) {
              velocidadFinal = velocidadCalc;
          }
        }
      }

      // Actualizamos referencias
      lastPosition = position;
      lastTime = DateTime.now();

      service.invoke('log', {"msg": "📡 Enviando datos (Vel: ${velocidadFinal.toInt()} km/h)..."});

      // --- INTENTO DE ENVÍO ---
      // 1. Historial
      final respHist = await http.post(
        Uri.parse('$apiUrl/historial/'),
        headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
        body: json.encode({
          "vehiculo": internalId,
          "latitud": position.latitude,
          "longitud": position.longitude,
          "velocidad": velocidadFinal.toInt(), // <--- AQUÍ USAMOS LA VARIABLE QUE CALCULAMOS
          "bateria": batteryLevel
        }),
      );

      // 2. Flota (Patch)
      await http.patch(
         Uri.parse('$apiUrl/flota/$internalId/'),
         headers: {"Content-Type": "application/json", "Authorization": "Token $token"},
         body: json.encode({ "ultima_posicion": {"type": "Point", "coordinates": [position.longitude, position.latitude]} })
      );

      // --- ÉXITO ---
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
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
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
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
          } catch (e) { /* Error silencioso config */ }

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('api_url', _apiUrlCtrl.text);
          await prefs.setString('api_token', _tokenCtrl.text);
          await prefs.setString('vehiculo_identifier', _idCtrl.text);
          await prefs.setInt('vehiculo_internal_id', data['id']);
          await prefs.setString('vehiculo_nombre', data['nombre']);
          await prefs.setString('vehiculo_matricula', data['matricula']);
          // Guardamos configuración
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
      appBar: AppBar(title: const Text("Configuración")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const Icon(Icons.settings_remote, size: 80, color: Colors.blue),
              const SizedBox(height: 20),
              TextField(controller: _apiUrlCtrl, decoration: const InputDecoration(labelText: "URL API", border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: _tokenCtrl, obscureText: true, decoration: const InputDecoration(labelText: "Token", border: OutlineInputBorder())),
              const SizedBox(height: 10),
              TextField(controller: _idCtrl, decoration: const InputDecoration(labelText: "ID Dispositivo", border: OutlineInputBorder())),
              const SizedBox(height: 20),
              _isLoading ? const CircularProgressIndicator() : ElevatedButton(onPressed: _saveAndConnect, child: const Text("Guardar y Conectar"))
            ],
          ),
        ),
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
  
  // Variables de estado visual
  String _statusText = "Iniciando servicio..."; // Cambiado mensaje inicial
  Color _statusColor = Colors.orange[100]!; 
  Color _iconColor = Colors.orange;
  IconData _statusIcon = Icons.sync;
  
  // --- LISTA DE LOGS VISUALES ---
  List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLocalData();
    _listenToService();
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nombre = prefs.getString('vehiculo_nombre') ?? "-";
      _matricula = prefs.getString('vehiculo_matricula') ?? "-";
    });
  }

  // --- ESCUCHA DE ESTADO Y LOGS ---
  void _listenToService() {
    final service = FlutterBackgroundService();
    
    // Escucha de estado general (color y texto grande)
    service.on('update').listen((event) {
      if (event != null && mounted) {
        setState(() {
          String time = "";
          try {
            time = event['last_update'].toString().split('T')[1].split('.')[0].substring(0, 5);
          } catch (e) { time = "--:--"; }
          
          String msg = event['msg'] ?? "";

          if (event['status'] == 'error') {
            _statusColor = Colors.red[100]!;
            _iconColor = Colors.red;
            _statusIcon = Icons.wifi_off;
            _statusText = "⚠️ ERROR: $msg\nHora: $time | Bat: ${event['bat']}%";
          } else if (event['status'] == 'loading') {
            _statusColor = Colors.orange[100]!;
            _iconColor = Colors.orange;
            _statusIcon = Icons.sync;
            _statusText = "⏳ $msg";
          } else {
            _statusColor = Colors.green[100]!;
            _iconColor = Colors.green;
            _statusIcon = Icons.check_circle;
            _statusText = "✅ $msg\nÚltimo: $time | Bat: ${event['bat']}%";
          }
        });
      }
    });

    // Escucha de LOGS detallados
    service.on('log').listen((event) {
      if (event != null && mounted) {
        setState(() {
          String time = DateTime.now().toString().split(' ')[1].split('.')[0];
          // Añadimos al principio de la lista
          _logs.insert(0, "[$time] ${event['msg']}");
          // Limitamos a 50 logs para no saturar memoria
          if (_logs.length > 50) _logs.removeLast();
        });
      }
    });
  }

  // --- VALIDACIÓN ONLINE DEL CÓDIGO ---
  Future<void> _verifyAndStop(String inputCode) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
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
      builder: (ctx) => const Center(child: CircularProgressIndicator())
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
        title: const Text("Código de Seguridad"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Introduce el código para detener."),
            const SizedBox(height: 10),
            TextField(
              controller: codeCtrl,
              // --- CORRECCIÓN 1: TECLADO ALFANUMÉRICO ---
              keyboardType: TextInputType.text, 
              textCapitalization: TextCapitalization.characters, // Sugerir mayúsculas
              obscureText: true,
              decoration: const InputDecoration(hintText: "Código", border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          ElevatedButton(
            onPressed: () => _verifyAndStop(codeCtrl.text),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text("Apagar"),
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
      appBar: AppBar(title: const Text("NavControl Driver"), automaticallyImplyLeading: false),
      body: Column( // Cambiado a Column para dividir la pantalla
        children: [
          // PARTE SUPERIOR (Tarjetas)
          Expanded(
            flex: 2, // Ocupa 2/3 de la pantalla (aprox)
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    elevation: 4,
                    child: ListTile(
                      leading: const Icon(Icons.local_shipping, size: 40, color: Colors.blue),
                      title: Text(_nombre, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("Matrícula: $_matricula"),
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: _statusColor, 
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _iconColor, width: 2)
                    ),
                    child: Row(
                      children: [
                         Icon(_statusIcon, color: _iconColor, size: 30),
                         const SizedBox(width: 15),
                         Expanded(
                           child: Text(
                             _statusText, 
                             style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 16)
                           )
                         )
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                  SwitchListTile(
                    title: const Text("Rastreo Activo"),
                    subtitle: const Text("Apagar enviará alerta a central"),
                    value: true, 
                    onChanged: _tryDisableTracking,
                    activeTrackColor: Colors.green,
                    activeThumbColor: Colors.white,
                  ),
                ],
              ),
            ),
          ),
          
          // PARTE INFERIOR (Log de Consola)
          // --- MEJORA 2: PANEL DE INFORMACIÓN DE CONEXIÓN ---
          const Divider(height: 1),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.grey[100],
            child: const Text("Log de Conexión (Diagnóstico)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          ),
          Expanded(
            flex: 1, // Ocupa el espacio restante
            child: Container(
              color: Colors.black87,
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      _logs[index],
                      style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier', fontSize: 12),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}