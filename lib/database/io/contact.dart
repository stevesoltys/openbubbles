import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// (needed when generating objectbox model code)
// ignore: unnecessary_import
import 'package:objectbox/objectbox.dart';
import 'package:slugify/slugify.dart';

@Entity()
class Contact {
  Contact({
    this.dbId,
    required this.id,
    required this.displayName,
    this.phones = const [],
    this.emails = const [],
    this.structuredName,
    this.avatar,
    this.isShared = false,
    this.isDismissed = false,
  });

  @Id()
  int? dbId;
  @Index()
  String id;
  String displayName;
  List<String> phones;
  List<String> emails;
  StructuredName? structuredName;
  Uint8List? avatar;
  bool isShared;
  bool isDismissed;

  String? get dbStructuredName => structuredName == null ? null : jsonEncode(structuredName!.toMap());
  set dbStructuredName(String? json) => structuredName = json == null ? null : StructuredName.fromMap(jsonDecode(json));

  String? get initials {
    String initials = (structuredName?.givenName.characters.firstOrNull ?? "") +
        (structuredName?.familyName.characters.firstOrNull ?? "");
    // If the initials are empty, get them from the display name
    if (initials.trim().isEmpty) {
      initials = displayName.characters.firstOrNull ?? "";
    }

    return initials.isEmpty ? null : initials.toUpperCase();
  }

  static List<Contact> getContacts() {
    return Database.contacts.getAll();
  }

  Contact save() {
    if (kIsWeb) return this;
    Database.runInTransaction(TxMode.write, () {
      Contact? existing = Contact.findOne(id: id);
      if (existing != null) {
        dbId = existing.dbId;
      }
      try {
        dbId = Database.contacts.put(this);
      } on UniqueViolationException catch (_) {}
    });
    return this;
  }

  static Contact? findOne({String? id, String? address, bool wantShared = false}) {
    if (kIsWeb) return null;
    if (id != null) {
      final query = Database.contacts.query(Contact_.id.equals(id)).build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    } else if (address != null) {
      var cond = Contact_.phones.containsElement(address) | Contact_.emails.containsElement(address);
      if (wantShared) {
        cond = cond.and(Contact_.isShared.equals(true));
      }
      final query =
          Database.contacts.query(cond)
          .order(Contact_.isShared).build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    }
    return null;
  }

  bool hasMatchingAddress(String search) {
    String term = slugify(search, delimiter: "");
    return phones.any((element) => slugify(element, delimiter: "").contains(term)) ||
        emails.any((element) => slugify(element, delimiter: "").contains(term));
  }

  Map<String, dynamic> toMap() {
    return {
      'dbId': dbId,
      'id': id,
      'displayName': displayName,
      'phoneNumbers': getUniqueNumbers(phones),
      'emails': getUniqueEmails(emails),
      'structuredName': structuredName?.toMap(),
      'avatar': avatar == null ? null : base64Encode(avatar!),
    };
  }

  static Contact fromMap(Map<String, dynamic> m) {
    return Contact(
      dbId: m['dbId'],
      id: m['id'],
      displayName: m['displayName'],
      phones: m['phoneNumbers'],
      emails: m['emails'],
      structuredName: StructuredName.fromMap(m['structuredName']),
      avatar: m['avatar'] == null ? null : base64Decode(m['avatar']!),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Contact &&
          runtimeType == other.runtimeType &&
          displayName == other.displayName &&
          listEquals(getUniqueNumbers(phones), getUniqueNumbers(other.phones)) &&
          listEquals(getUniqueEmails(emails), getUniqueEmails(other.emails)) &&
          avatar?.length == other.avatar?.length);

  @override
  int get hashCode =>
      Object.hashAllUnordered([displayName, avatar?.length, ...getUniqueNumbers(phones), ...getUniqueEmails(emails)]);
}
