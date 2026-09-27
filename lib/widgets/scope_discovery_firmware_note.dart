import 'package:flutter/material.dart';

/// The extra line shown under the Scope Discovery switch while the connected
/// radio's companion firmware is below the feature's floor (companion
/// firmware v1.16.0). The switch keeps working either way: the setting is
/// saved, but nothing is asked and nothing extra goes on the air until the
/// firmware catches up.
class ScopeDiscoveryFirmwareNote extends StatelessWidget {
  const ScopeDiscoveryFirmwareNote({super.key, required this.show});

  final bool show;

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        'Your radio needs firmware v1.16.0 or newer for this.',
        style: TextStyle(color: Colors.amber, fontSize: 12),
      ),
    );
  }
}

/// The extra line shown under the Scope Discovery switch while the connected
/// radio's contact table is full and this connection has stopped asking a
/// repeater that is not a saved contact (a companion firmware bug: it needs
/// a contact-table slot for the send, fixed in v1.17.0). Saved contacts are
/// unaffected and are still asked normally.
class ScopeDiscoveryContactsFullNote extends StatelessWidget {
  const ScopeDiscoveryContactsFullNote({super.key, required this.show});

  final bool show;

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        "Your radio's contact list is full, so only repeaters saved as "
        'contacts can be asked. Companion firmware v1.17 or newer fixes '
        'this, or remove some contacts.',
        style: TextStyle(color: Colors.amber, fontSize: 12),
      ),
    );
  }
}
