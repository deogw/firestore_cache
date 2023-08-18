import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'exceptions.dart';

/// FirestoreCache is a Flutter plugin for fetching Firestore documents with
/// read from cache first then server.
///
/// Before using this plugin, you will need to do some inital setup on
/// Firestore. Then you can use this sample code to fetch documents:
///
/// ```dart
/// import 'package:cloud_firestore/cloud_firestore.dart';
/// import 'package:firestore_cache/firestore_cache.dart';
///
/// // This should be the path of the document containing the timestampe field
/// // that you created
/// final cacheDocRef = Firestore.instance.doc('status/status');
///
/// // This should be the timestamp field in that document
/// final cacheField = 'updatedAt';
///
/// final query = Firestore.instance.collection('posts');
/// final snapshot = await FirestoreCache.getDocuments(
///     query: query,
///     cacheDocRef: cacheDocRef,
///     firestoreCacheField: cacheField,
/// );
/// ```
class FirestoreCache {
  /// Fetch a document with read from cache first then server.
  ///
  /// This method takes in a [docRef] which is the usual [DocumentReference]
  /// object on Firestore used for retrieving a single document. It tries to
  /// fetch the document from the cache first, and fallback to retrieving from
  /// the server if it fails to do so.
  ///
  /// It also takes in the optional arguments [source] which you can force it to
  /// fetch the document from the server, and [isRefreshEmptyCache] to refresh
  /// the cached document from the server if it is empty.
  ///
  /// This method should only be used if the document you are fetching does not
  /// change over time. Once the document is cached, it will always be read from
  /// the cache.
  static Future<DocumentSnapshot<Map<String, dynamic>>> getDocument(
    DocumentReference<Map<String, dynamic>> docRef, {
    Source source = Source.cache,
    bool isRefreshEmptyCache = true,
  }) async {
    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await docRef.get(GetOptions(source: source));
      if (doc.data() == null && isRefreshEmptyCache) doc = await docRef.get();
    } on FirebaseException {
      // Document cache is unavailable so we fallback to default get document
      // behavior.
      doc = await docRef.get();
    }

    return doc;
  }

  /// Fetch documents once with read from cache first then server, based on a date system.
  ///
  /// Will attempt to read the [firestoreCacheField] field of the [cacheDocRef] document to determine if the cache is stale.
  /// So it may cost 1 read, even if cache is up to date.
  /// And it may cause some delay when offline (waiting for timeout).
  ///
  /// Use [cacheOnly] to force reading from cache only, skipping server's date check.
  /// In that case, if cache is empty, it will return an empty snapshot.
  ///
  /// This method takes in a [query] which is the usual Firestore [Query] object
  /// used to query a collection, and a [cacheDocRef] which is the timestamp
  /// [DocumentReference] object of the document containing the
  /// [firestoreCacheField] field of [Timestamp] or [String]. If the field is a
  /// [String], it must be parsable by [DateTime.parse]. Otherwise
  /// [FormatException] will be thrown.
  ///
  /// If [cacheDocRef] does not exist, [CacheDocDoesNotExist] will be thrown.
  /// And if [firestoreCacheField] does not exist, [CacheDocFieldDoesNotExist]
  /// will be thrown.
  ///
  /// You can also pass in [localCacheKey] as the key for storing the last local
  /// cache date, and [isUpdateCacheDate] to set if it should update the last
  /// local cache date to current date and time.
  ///
  /// You can also pass in [serversDateRaw] to provide the latest server's date to be compared to, to avoid a read operation.
  static Future<QuerySnapshot<Map<String, dynamic>>> getDocuments({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> cacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool isUpdateCacheDate = true,
    bool cacheOnly = false,
    dynamic serversDateRaw,
  }) async {
    // If it is set to read from cache only, directly return the snapshot from cache, without fallback.
    if (cacheOnly) {
      return await query.get(const GetOptions(source: Source.cache));
    }

    // Determine whether to fetch documents from cache or server.
    localCacheKey = localCacheKey ?? firestoreCacheField;
    final shouldFetch = await shouldFetchDocuments(
      cacheDocRef,
      firestoreCacheField,
      localCacheKey,
      serversDateRaw,
    );
    final src = shouldFetch ? Source.serverAndCache : Source.cache;

    // Fetch documents from source.
    var snapshot = await query.get(GetOptions(source: src));

    // If it is triggered to get documents from cache but the documents do not
    // exist, which means documents may have been removed from cache, we then
    // fallback to default get documents behavior.
    if (src == Source.cache && snapshot.docs.isEmpty) {
      snapshot = await query.get();
    }

    // If it is set to update cache date, and there are documents in the
    // snapshot, and at least one of the documents was retrieved from the
    // server, update the latest local cache date.
    if (isUpdateCacheDate &&
        snapshot.docs.isNotEmpty &&
        snapshot.docs.any((doc) => doc.metadata.isFromCache == false)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(localCacheKey, DateTime.now().toIso8601String());
    }

    return snapshot;
  }

  /// Like [getDocuments], but returns a [Stream] of [QuerySnapshot] instead.
  /// Will quickly emmit a value from cache, then listen and emmit changes.
  ///
  /// See [getDocuments] for more details.
  static Stream<QuerySnapshot<Map<String, dynamic>>> getDocumentsSnapshots({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> cacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool isUpdateCacheDate = true,
  }) {
    // It's fine to let the StreamController be garbage collected once all the
    // subscribers have cancelled; this analyzer warning is safe to ignore.
    late StreamController<QuerySnapshot<Map<String, dynamic>>> controller; // ignore: close_sinks

    StreamSubscription<DocumentSnapshot>? snapshotStreamSubscription;
    controller = StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast(
      onListen: () async {
        // Push cached data first
        controller.add(await query.get(const GetOptions(source: Source.cache)));

        // Then listen to [firestoreCacheField] changes
        snapshotStreamSubscription = cacheDocRef.snapshots().listen((doc) async {
          // Get server's date
          final serversDateRaw = doc.data()?[firestoreCacheField];

          // Get data from cache or server, providing latest server's date
          final snapshot = await getDocuments(
            query: query,
            cacheDocRef: cacheDocRef,
            firestoreCacheField: firestoreCacheField,
            localCacheKey: localCacheKey,
            isUpdateCacheDate: isUpdateCacheDate,
            serversDateRaw: serversDateRaw,
          );

          // Push new value if it's new (from server)
          if (!snapshot.metadata.isFromCache) {
            controller.add(snapshot);
          }
        }, onError: controller.addError);
      },
      onCancel: () => snapshotStreamSubscription?.cancel(),
    );

    return controller.stream;
  }

  @visibleForTesting
  static Future<bool> shouldFetchDocuments(
    DocumentReference<Map<String, dynamic>> cacheDocRef,
    String firestoreCacheField,
    String localCacheKey,
    dynamic serverDateRaw,
  ) async {
    var shouldFetch = true;
    final prefs = await SharedPreferences.getInstance();
    final dateStr = prefs.getString(localCacheKey);

    if (dateStr != null) {
      final cacheDate = DateTime.parse(dateStr);

      if (serverDateRaw == null) {
        final doc = await cacheDocRef.get();
        final data = doc.data();
        if (!doc.exists) {
          throw CacheDocDoesNotExist();
        } else if (data == null || !data.containsKey(firestoreCacheField)) {
          throw CacheDocFieldDoesNotExist();
        }
        serverDateRaw = data[firestoreCacheField];
      }

      DateTime? serverDate;
      if (serverDateRaw is Timestamp) {
        serverDate = serverDateRaw.toDate();
      } else if (serverDateRaw is String) {
        serverDate = DateTime.tryParse(serverDateRaw);
      }

      if (serverDate == null) {
        throw FormatException('Invalid date format', serverDateRaw);
      } else if (serverDate.isBefore(cacheDate) == true) {
        shouldFetch = false;
      }
    }

    return shouldFetch;
  }
}
