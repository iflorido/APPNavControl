import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const NavControlApp());
}

class NavControlApp extends StatelessWidget {
  const NavControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NavControl Driver',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // --- CONFIGURACIÓN ---
  final TextEditingController _apiUrlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController(); // NUEVO: Token editable
  final TextEditingController _identifierController = TextEditingController();
  
  // --- ESTADO ---
  bool _isConfigured = false;
  bool _isTracking = true;
  String _statusMessage = "Esperando configuración...";
  
  // --- DATOS VEHÍCULO ---
  int? _internalId; 
  String _nombreVehiculo = "-";
  String _matricula = "-";
  String _codigoDesbloqueoReal = ""; 
  
  Timer? _timer;
  final Battery _battery = Battery();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _requestPermissions();
  }

  // 1. CARGAR CONFIGURACIÓN
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUrlController.text = prefs.getString('api_url') ?? 'https://navcontrol.automaworks.es/api';
      // Token por defecto vacío o el que tenías para facilitar pruebas
      _tokenController.text = prefs.getString('api_token') ?? 'e588558833e4365f809cb273a587e962b054c9e7';
      _identifierController.text = prefs.getString('vehiculo_identifier') ?? '';
      
      if (_identifierController.text.isNotEmpty && _tokenController.text.isNotEmpty) {
        _fetchVehicleInfo(); 
      }
    });
  }

  Future<void> _requestPermissions() async {
    await [Permission.location].request();
  }

  // 2. GUARDAR CONFIGURACIÓN
  Future<void> _saveSettings() async {
    // Validamos conexión antes de guardar
    await _fetchVehicleInfo();
    
    if (_internalId != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_url', _apiUrlController.text);
      await prefs.setString('api_token', _tokenController.text); // Guardamos el token
      await prefs.setString('vehiculo_identifier', _identifierController.text);
    }
  }

  void _startTrackingLoop() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isTracking && _isConfigured && _internalId != null) {
        _sendTelemetry();
      }
    });
  }

  // 3. BUSCAR VEHÍCULO (Usando Token dinámico)
  Future<void> _fetchVehicleInfo() async {
    try {
      setState(() => _statusMessage = "Conectando...");
      
      final url = '${_apiUrlController.text}/flota/?identificador=${_identifierController.text}';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          "Content-Type": "application/json", 
          "Authorization": "Token ${_tokenController.text}" // USA EL TOKEN DEL CAMPO DE TEXTO
        },
      );

      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(utf8.decode(response.bodyBytes));
        
        if (results.isNotEmpty) {
          final data = results[0]; 
          
          setState(() {
            _internalId = data['id']; 
            _nombreVehiculo = data['nombre'];
            _matricula = data['matricula'];
            _codigoDesbloqueoReal = data['codigo_seguridad'] ?? "0000"; 
            _isConfigured = true;
            _statusMessage = "Conectado: $_nombreVehiculo";
          });
          
          _startTrackingLoop();
          
        } else {
           setState(() {
             _statusMessage = "❌ ID no encontrado: ${_identifierController.text}";
             _isConfigured = false;
           });
        }
      } else {
        setState(() => _statusMessage = "Error API (${response.statusCode}): Revise Token/URL");
      }
    } catch (e) {
      debugPrint("Error: $e");
      setState(() => _statusMessage = "Error de Conexión");
    }
  }

  // 4. ENVIAR DATOS (Usando Token dinámico)
  Future<void> _sendTelemetry() async {
    if (_internalId == null) return;

    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      int batteryLevel = await _battery.batteryLevel;

      final urlHistorial = '${_apiUrlController.text}/historial/';
      final payload = {
        "vehiculo": _internalId,
        "latitud": position.latitude,
        "longitud": position.longitude,
        "velocidad": position.speed.toInt() * 3.6,
        "bateria": batteryLevel
      };

      final response = await http.post(
        Uri.parse(urlHistorial),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Token ${_tokenController.text}" // TOKEN DINÁMICO
        },
        body: json.encode(payload),
      );
      
      await http.patch(
         Uri.parse('${_apiUrlController.text}/flota/$_internalId/'),
         headers: {
          "Content-Type": "application/json",
          "Authorization": "Token ${_tokenController.text}" // TOKEN DINÁMICO
         },
         body: json.encode({
           "ultima_posicion": {"type": "Point", "coordinates": [position.longitude, position.latitude]}
         })
      );

      debugPrint("📡 Telemetría enviada (ID: $_internalId): ${response.statusCode}");
      
      setState(() {
         _statusMessage = "Último envío: ${TimeOfDay.now().format(context)} | Bat: $batteryLevel%";
      });

    } catch (e) {
      debugPrint("Error enviando: $e");
    }
  }

  void _toggleTracking(bool value) async {
    if (value == false) {
      _showUnlockDialog();
    } else {
      setState(() => _isTracking = true);
      _statusMessage = "Seguimiento REACTIVADO";
    }
  }

  Future<void> _showUnlockDialog() async {
    String inputCode = "";
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('🔐 Desactivar Localización'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                const Text('Introduce el código de seguridad.'),
                const SizedBox(height: 10),
                TextField(
                  onChanged: (value) => inputCode = value,
                  decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "Código"),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            FilledButton(
              child: const Text('Verificar'),
              onPressed: () {
                if (inputCode == _codigoDesbloqueoReal) {
                   setState(() {
                     _isTracking = false;
                     _statusMessage = "⚠️ SEGUIMIENTO PAUSADO";
                   });
                   Navigator.of(context).pop();
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Desactivado")));
                } else {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.red, content: Text("Código Incorrecto")));
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isConfigured) {
      // --- PANTALLA DE CONFIGURACIÓN ---
      return Scaffold(
        appBar: AppBar(title: const Text("Configuración del Terminal")),
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: SingleChildScrollView( // Para evitar overflow con el teclado
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.phonelink_setup, size: 80, color: Colors.blue),
                const SizedBox(height: 20),
                
                TextField(
                  controller: _apiUrlController,
                  decoration: const InputDecoration(
                    labelText: "URL del Servidor", 
                    hintText: "https://midominio.com/api",
                    border: OutlineInputBorder()
                  ),
                ),
                const SizedBox(height: 10),
                
                TextField(
                  controller: _tokenController,
                  obscureText: true, // Ocultar el token por seguridad visual
                  decoration: const InputDecoration(
                    labelText: "Token de API", 
                    border: OutlineInputBorder(),
                    helperText: "Token proporcionado por el administrador"
                  ),
                ),
                const SizedBox(height: 10),
                
                TextField(
                  controller: _identifierController,
                  decoration: const InputDecoration(
                    labelText: "ID Dispositivo (Ej: TRUCK-01)", 
                    border: OutlineInputBorder(),
                    helperText: "Identificador único del vehículo"
                  ),
                ),
                const SizedBox(height: 20),
                
                ElevatedButton.icon(
                  onPressed: _saveSettings,
                  icon: const Icon(Icons.save),
                  label: const Text("Guardar y Conectar"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                  ),
                )
              ],
            ),
          ),
        ),
      );
    }

    // --- PANTALLA PRINCIPAL ---
    return Scaffold(
      appBar: AppBar(
        title: const Text("NavControl Driver"),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: () async {
            final prefs = await SharedPreferences.getInstance();
            prefs.clear();
            setState(() {
               _isConfigured = false;
               _internalId = null;
               _identifierController.clear();
               _tokenController.clear();
            });
          })
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Icon(Icons.local_shipping, size: 50, color: Colors.blueGrey),
                    const SizedBox(height: 10),
                    Text(_nombreVehiculo, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    Text("Matrícula: $_matricula", style: const TextStyle(fontSize: 18, color: Colors.grey)),
                    const Divider(),
                    Text("ID: ${_identifierController.text}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _isTracking ? Colors.green.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _isTracking ? Colors.green : Colors.red)
              ),
              child: Row(
                children: [
                  Icon(_isTracking ? Icons.gps_fixed : Icons.gps_off, color: _isTracking ? Colors.green : Colors.red),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_statusMessage, style: TextStyle(color: _isTracking ? Colors.green[800] : Colors.red[800]))),
                ],
              ),
            ),
            
            const SizedBox(height: 20),

            SwitchListTile(
              title: const Text("Localización Activa"),
              subtitle: const Text("Requiere código de seguridad"),
              value: _isTracking,
              activeTrackColor: Colors.green, 
              activeThumbColor: Colors.white, 
              onChanged: _toggleTracking, 
            ),
            
            const Spacer(),
            // Mostramos solo parte del Token por seguridad
            Text("API: ${_apiUrlController.text}", style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}