import 'package:flutter/material.dart';
import 'package:keychain/keychain.dart';

void main() {
  // This example has no DI framework of its own: build the repository once
  // here and pass it down.
  runApp(KeychainExampleApp(keychain: KeychainRepository()));
}

class KeychainExampleApp extends StatelessWidget {
  const KeychainExampleApp({super.key, required this.keychain});

  final KeychainRepository keychain;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('keychain example')),
        body: Center(
          child: StreamBuilder<bool>(
            stream: keychain.availabilityChanges,
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
              final bool? available = snapshot.data;
              return Text(
                available == null ? 'Reading…' : 'Available: $available',
                style: Theme.of(context).textTheme.headlineSmall,
              );
            },
          ),
        ),
        floatingActionButton: _KeychainExampleCreateButton(keychain: keychain),
      ),
    );
  }
}

class _KeychainExampleCreateButton extends StatelessWidget {
  const _KeychainExampleCreateButton({required this.keychain});

  static const String _keyId = 'demo.token';

  final KeychainRepository keychain;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () => _createOrRead(context),
      label: const Text('Create or read demo.token'),
    );
  }

  Future<void> _createOrRead(BuildContext context) async {
    String outcome;
    try {
      await keychain.create(_keyId);
      outcome = 'Created $_keyId';
    } on KeychainKeyAlreadyExistsException {
      final KeychainKeyEntity key = await keychain.read(_keyId);
      outcome = 'Read $_keyId: ${key.material.length} bytes';
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(outcome)));
    }
  }
}
