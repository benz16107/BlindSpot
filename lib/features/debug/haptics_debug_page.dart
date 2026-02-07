import 'package:flutter/material.dart';
import 'package:sesesesese/core/haptics/haptics.dart';

/// Manual test screen to demo vibration patterns (e.g. for judges).
/// Does not assume how this page is opened; use as a route target.
class HapticsDebugPage extends StatefulWidget {
  const HapticsDebugPage({super.key});

  @override
  State<HapticsDebugPage> createState() => _HapticsDebugPageState();
}

class _HapticsDebugPageState extends State<HapticsDebugPage> {
  bool? _supported;

  @override
  void initState() {
    super.initState();
    _checkSupport();
  }

  Future<void> _checkSupport() async {
    final supported = await Haptics.isSupported();
    if (mounted) setState(() => _supported = supported);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haptics Debug'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Vibration supported: ${_supported == null ? "…" : _supported! ? "Yes" : "No"}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => Haptics.leftTurn(),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
                child: const Text('Test Left Turn'),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Haptics.rightTurn(),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
                child: const Text('Test Right Turn'),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Haptics.dangerStop(),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
                child: const Text('Test Danger / Stop'),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: () => Haptics.cancel(),
                child: const Text('Cancel Vibration'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
