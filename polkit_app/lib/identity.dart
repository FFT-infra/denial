import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent.dart';

/// How an account is presented. Missing or unreadable sources fall back to
/// the account name and a monogram; none of this affects authorization.
@immutable
class IdentityProfile {
  const IdentityProfile({required this.displayName, this.avatar});

  final String displayName;

  /// Encoded image bytes, decoded by the presentation at its display size.
  final Uint8List? avatar;
}

const _maximumAvatarBytes = 4 * 1024 * 1024;
final _accountName = RegExp(r'^[A-Za-z0-9._][A-Za-z0-9._-]*\$?$');
final _denialAvatarName = RegExp(r'^avatar-[0-9]+-[0-9]+\.png$');

Future<IdentityProfile> loadIdentityProfile(
  AgentIdentity identity,
  Map<String, String> environment,
) async {
  final name = identity.name;
  // Names become path components below; never follow anything unusual.
  if (!_accountName.hasMatch(name)) {
    return IdentityProfile(displayName: name);
  }
  final current = environment['USER'] == name || environment['LOGNAME'] == name;
  String? displayName;
  Uint8List? avatar;
  if (current) {
    (displayName, avatar) = await _denialProfile(environment);
  }
  if (identity.uid == 0) displayName ??= 'Administrator';
  displayName ??= await _passwdRealName(name);
  avatar ??= await _image('/var/lib/AccountsService/icons/$name');
  final home = environment['HOME'];
  if (current && home != null && home.startsWith('/')) {
    avatar ??= await _image('$home/.face.icon') ?? await _image('$home/.face');
  }
  return IdentityProfile(displayName: displayName ?? name, avatar: avatar);
}

/// The reference desktop's own profile, shown when the user authenticates as
/// themselves. It is read-only here; Settings remains its only writer.
Future<(String?, Uint8List?)> _denialProfile(
  Map<String, String> environment,
) async {
  final configured = environment['XDG_CONFIG_HOME'];
  final home = environment['HOME'];
  final root = configured != null && configured.startsWith('/')
      ? configured
      : home != null && home.startsWith('/')
      ? '$home/.config'
      : null;
  if (root == null) return (null, null);
  final directory = '$root/denial/plugins/denial_desktop/profile';
  try {
    final document = File('$directory/profile.json');
    if (await document.length() > 65536) return (null, null);
    final value = jsonDecode(await document.readAsString());
    if (value is! Map || value['schema'] != 1) return (null, null);
    final name = value['displayName'];
    final avatar = value['avatar'];
    return (
      name is String && name.trim().isNotEmpty && name.runes.length <= 200
          ? name.trim()
          : null,
      avatar is String && _denialAvatarName.hasMatch(avatar)
          ? await _image('$directory/$avatar')
          : null,
    );
  } on FileSystemException {
    return (null, null);
  } on FormatException {
    return (null, null);
  }
}

Future<String?> _passwdRealName(String name) async {
  try {
    for (final line in await File('/etc/passwd').readAsLines()) {
      final fields = line.split(':');
      if (fields.length < 5 || fields.first != name) continue;
      final realName = fields[4].split(',').first.trim();
      return realName.isEmpty || realName == name ? null : realName;
    }
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  return null;
}

Future<Uint8List?> _image(String path) async {
  try {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size == 0 ||
        stat.size > _maximumAvatarBytes) {
      return null;
    }
    return await file.readAsBytes();
  } on FileSystemException {
    return null;
  }
}
