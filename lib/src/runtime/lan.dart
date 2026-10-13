import 'dart:io';

/// Addresses another device on the same network could reach this phone at.
///
/// The server binds to `0.0.0.0`, so every interface answers, but the user only
/// cares about the one on the Wi-Fi they are sitting on. Loopback and the
/// mobile radio's own interface are filtered out: neither is something a laptop
/// can type.
Future<List<String>> lanAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        // 169.254 is link-local: it means the interface has no real address.
        if (address.address.startsWith('169.254.')) continue;
        addresses.add(address.address);
      }
    }
    addresses.sort();
    return addresses;
  } catch (_) {
    // Listing interfaces is not allowed everywhere; an empty list just means the
    // screen shows "no network address" rather than a wrong one.
    return const [];
  }
}

/// The link-local IPv6 and IPv4 addresses are noise; this keeps the useful one
/// when there are several.
String? preferredLanAddress(List<String> addresses) =>
    addresses.isEmpty ? null : addresses.first;