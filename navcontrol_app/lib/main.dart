import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Eliminado permission_handler (usaremos Geolocator)
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// Eliminado el import redundante de android

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

  // Configuración para Android
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

  // Bucle infinito
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    final String? apiUrl = prefs.getString('api_url');
    final String? token = prefs.getString('api_token');
    final int? internalId = prefs.getInt('vehiculo_internal_id');

    if (apiUrl == null || token == null || internalId == null) {
      return; 
    }

    // Actualizar notificación en Android
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "NavControl Activo",
        content: "Último envío: ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}",
      );
    }

    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      int batteryLevel = await Battery().batteryLevel;

      // 1. Enviar Historial
      await http.post(
        Uri.parse('$apiUrl/historial/'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Token $token"
        },
        body: json.encode({
          "vehiculo": internalId,
          "latitud": position.latitude,
          "longitud": position.longitude,
          "velocidad": (position.speed * 3.6).toInt(),
          "bateria": batteryLevel
        }),
      );

      // 2. Actualizar Ubicación Flota
      await http.patch(
         Uri.parse('$apiUrl/flota/$internalId/'),
         headers: { "Content-Type": "application/json", "Authorization": "Token $token" },
         body: json.encode({ "ultima_posicion": {"type": "Point", "coordinates": [position.longitude, position.latitude]} })
      );

      debugPrint("📡 [Background] OK ID: $internalId");
      
      // Enviar datos a la UI
      service.invoke(
        'update',
        {
          "last_update": DateTime.now().toIso8601String(),
          "bat": batteryLevel,
        },
      );

    } catch (e) {
      debugPrint("❌ [Background] Error: $e");
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
    // 1. Pedimos permisos usando Geolocator directamente (sin permission_handler)
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    // 2. Comprobamos sesión
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
      final url = '${_apiUrlCtrl.text}/flota/?identificador=${_idCtrl.text}';
      final response = await http.get(Uri.parse(url), headers: {
        "Content-Type": "application/json", "Authorization": "Token ${_tokenCtrl.text}"
      });

      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(utf8.decode(response.bodyBytes));
        if (results.isNotEmpty) {
          final data = results[0];
          
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('api_url', _apiUrlCtrl.text);
          await prefs.setString('api_token', _tokenCtrl.text);
          await prefs.setString('vehiculo_identifier', _idCtrl.text);
          await prefs.setInt('vehiculo_internal_id', data['id']);
          await prefs.setString('vehiculo_nombre', data['nombre']);
          await prefs.setString('vehiculo_matricula', data['matricula']);
          await prefs.setString('vehiculo_codigo', data['codigo_seguridad'] ?? "0000");

          // Arrancar Servicio
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
  String _codigoReal = "";
  String _status = "Servicio Activo";

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
      _codigoReal = prefs.getString('vehiculo_codigo') ?? "";
    });
  }

  void _listenToService() {
    FlutterBackgroundService().on('update').listen((event) {
      if (event != null && mounted) {
        setState(() {
          final time = event['last_update'].toString().split('T')[1].split('.')[0];
          _status = "Último: $time | Bat: ${event['bat']}%";
        });
      }
    });
  }

  // Función para enviar alerta antes de cerrar
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
            "tipo": "PARADA", // Asegúrate de que este tipo existe en tu modelo Django
            "mensaje": "⚠️ ALERTA: App cerrada manualmente.",
            "leido": false
          }),
        );
        debugPrint("🚨 Alerta de cierre enviada.");
      } catch (e) {
        debugPrint("Error enviando alerta cierre: $e");
      }
    }
  }

  Future<void> _stopServiceAndLogout() async {
    // 1. Enviar Alerta
    await _sendClosingAlert();

    // 2. Parar servicio
    final service = FlutterBackgroundService();
    service.invoke("stopService"); 
    
    // 3. Borrar sesión
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    if (mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ConfigScreen()));
    }
  }

  void _tryDisableTracking(bool value) {
    if (!value) {
      showDialog(context: context, builder: (ctx) => AlertDialog(
        title: const Text("Código de Seguridad"),
        content: TextField(
          decoration: const InputDecoration(hintText: "Introduce código para cerrar"),
          onSubmitted: (code) {
             if (code == _codigoReal) {
               Navigator.pop(ctx);
               _stopServiceAndLogout(); 
             } else {
               Navigator.pop(ctx);
               ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Código Incorrecto"), backgroundColor: Colors.red));
             }
          },
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("NavControl Driver"), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.local_shipping, size: 40),
                title: Text(_nombre, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text("Matrícula: $_matricula"),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.green[100], borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                   const Icon(Icons.sync, color: Colors.green),
                   const SizedBox(width: 10),
                   Expanded(child: Text(_status, style: TextStyle(color: Colors.green[900])))
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
            const Spacer(),
            const Text("Cerrar esta pantalla no detiene el GPS.", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }
}