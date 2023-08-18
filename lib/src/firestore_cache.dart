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
/// final firebaseCacheDocRef = Firestore.instance.doc('status/status');
///
/// // This should be the timestamp field in that document
/// final cacheField = 'updatedAt';
///
/// final query = Firestore.instance.collection('posts');
/// final snapshot = await FirestoreCache.getDocuments(
///     query: query,
///     firebaseCacheDocRef: firebaseCacheDocRef,
///     firestoreCacheField: cacheField,
/// );
/// ```
class FirestoreCache {
  /// Whether to enable logs.
  static var enableLogs = true;
  static void _log(String message) {
    if (enableLogs) debugPrint(message);
  }

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

    _log('[FirestoreCache] document "${docRef.path}" fetched from ${doc.metadata.isFromCache ? 'cache' : 'server'}');
    return doc;
  }

  /// Fetch documents once from cache first then server, based on a date system.
  ///
  /// Will attempt to read the [firestoreCacheField] field of the [firebaseCacheDocRef] document to determine if the cache is stale.
  /// So it may cost 1 read, even if cache is up to date.
  /// And it may cause some delay when offline (waiting for timeout).
  ///
  /// Use [cacheMode] to choose cache behavior.
  ///
  /// This method takes in a [query] which is the usual Firestore [Query] object
  /// used to query a collection, and a [firebaseCacheDocRef] which is the timestamp
  /// [DocumentReference] object of the document containing the
  /// [firestoreCacheField] field of [Timestamp] or [String]. If the field is a
  /// [String], it must be parsable by [DateTime.parse]. Otherwise
  /// [FormatException] will be thrown.
  ///
  /// If [firebaseCacheDocRef] does not exist, [CacheDocDoesNotExist] will be thrown.
  /// And if [firestoreCacheField] does not exist, [CacheDocFieldDoesNotExist]
  /// will be thrown.
  ///
  /// You can also pass in [localCacheKey] as the key for storing the last local
  /// cache date, and [updateLocalCacheDate] to set if it should update the last
  /// local cache date to current date and time.
  ///
  /// You can also pass in [serverDateRaw] to provide the latest server's date to be compared to, to avoid a read operation.
  static Future<QuerySnapshot<Map<String, dynamic>>> getDocuments({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> firebaseCacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool updateLocalCacheDate = true,
    FirestoreCacheMode cacheMode = FirestoreCacheMode.cacheOrServer,
    dynamic serverDateRaw,
  }) {
    switch (cacheMode) {
      case FirestoreCacheMode.cacheOrServer:
        return getDocumentsFromCacheOrServer(
          query: query,
          firebaseCacheDocRef: firebaseCacheDocRef,
          firestoreCacheField: firestoreCacheField,
          localCacheKey: localCacheKey,
          updateLocalCacheDate: updateLocalCacheDate,
          serverDateRaw: serverDateRaw,
        );
      case FirestoreCacheMode.cacheThenServer:
        return getDocumentsFromCacheThenServer(
          query: query,
          firebaseCacheDocRef: firebaseCacheDocRef,
          firestoreCacheField: firestoreCacheField,
          localCacheKey: localCacheKey,
          updateLocalCacheDate: updateLocalCacheDate,
          serverDateRaw: serverDateRaw,
        );
      case FirestoreCacheMode.cacheOnly:
        return getDocumentsFromCacheOnly(
          query: query,
        );
    }
  }

  /// Shortcut for [getDocuments] with [cacheMode] set to [FirestoreCacheMode.cacheOrServer].
  static Future<QuerySnapshot<Map<String, dynamic>>> getDocumentsFromCacheOrServer({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> firebaseCacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool updateLocalCacheDate = true,
    dynamic serverDateRaw,
  }) async {
    // Determine whether to fetch documents from cache or server.
    localCacheKey = localCacheKey ?? firestoreCacheField;
    final shouldFetch = await shouldFetchDocuments(
      firebaseCacheDocRef,
      firestoreCacheField,
      localCacheKey,
      serverDateRaw,
    );

    // Fetch documents from source.
    return await _getDocumentsFromSource(
      query: query,
      source: shouldFetch ? Source.serverAndCache : Source.cache,
      localCacheKey: localCacheKey,
      updateLocalCacheDate: updateLocalCacheDate,
    );
  }

  /// Shortcut for [getDocuments] with [cacheMode] set to [FirestoreCacheMode.cacheThenServer].
  static Future<QuerySnapshot<Map<String, dynamic>>> getDocumentsFromCacheThenServer({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> firebaseCacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool updateLocalCacheDate = true,
    dynamic serverDateRaw,
  }) async {
    // Get documents from cache first
    final task = getDocumentsFromCacheOnly(query: query);

    // Update cache from server in background
    unawaited(() async {
      // Determine whether to fetch documents from cache or server.
      localCacheKey = localCacheKey ?? firestoreCacheField;
      final shouldFetch = await shouldFetchDocuments(
        firebaseCacheDocRef,
        firestoreCacheField,
        localCacheKey!,
        serverDateRaw,
      );

      // Ignore if no need to update cache
      if (!shouldFetch) return;

      // Fetch documents from source.
      await _getDocumentsFromSource(
        query: query,
        source: Source.serverAndCache,
        localCacheKey: localCacheKey!,
        updateLocalCacheDate: updateLocalCacheDate,
      );
    } ());

    // Wait for cache result
    return await task;
  }

  /// Shortcut for [getDocuments] with [cacheMode] set to [FirestoreCacheMode.cacheOnly].
  static Future<QuerySnapshot<Map<String, dynamic>>> getDocumentsFromCacheOnly({
    required Query<Map<String, dynamic>> query,
  }) async {
    final snapshot = await query.get(const GetOptions(source: Source.cache));
    _log('[FirestoreCache] ${snapshot.docs.length} documents fetched from cache, with query: "${query.toString()}"');
    return snapshot;
  }

  /// Fetch documents from [source].
  /// If [source] is [Source.cache], will fallback to [Source.server] if cache is empty.
  /// If [updateLocalCacheDate] is true, will update the local cache date if needed.
  static Future<QuerySnapshot<Map<String, dynamic>>> _getDocumentsFromSource({
    required Query<Map<String, dynamic>> query,
    required Source source,
    required String localCacheKey,
    bool updateLocalCacheDate = true,
  }) async {
    // Fetch documents from source.
    var snapshot = await query.get(GetOptions(source: source));

    // If it is triggered to get documents from cache but the documents do not
    // exist, which means documents may have been removed from cache, we then
    // fallback to default get documents behavior.
    if (source == Source.cache && snapshot.docs.isEmpty) {
      snapshot = await query.get();
    }

    // If it is set to update cache date, and there are documents in the
    // snapshot, and at least one of the documents was retrieved from the
    // server, update the latest local cache date.
    if (updateLocalCacheDate &&
        snapshot.docs.isNotEmpty &&
        snapshot.docs.any((doc) => doc.metadata.isFromCache == false)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(localCacheKey, DateTime.now().toIso8601String());
    }

    _log('[FirestoreCache] ${snapshot.docs.length} documents fetched from ${snapshot.metadata.isFromCache ? 'cache' : 'server'}, with query: "${query.toString()}"');
    return snapshot;
  }

  /// Like [getDocuments], but returns a [Stream] of [QuerySnapshot] instead.
  /// Will quickly emmit a value from cache, then listen and emmit changes.
  ///
  /// See [getDocuments] for more details.
  static Stream<QuerySnapshot<Map<String, dynamic>>> getDocumentsSnapshots({
    required Query<Map<String, dynamic>> query,
    required DocumentReference<Map<String, dynamic>> firebaseCacheDocRef,
    required String firestoreCacheField,
    String? localCacheKey,
    bool updateLocalCacheDate = true,
  }) {
    // It's fine to let the StreamController be garbage collected once all the
    // subscribers have cancelled; this analyzer warning is safe to ignore.
    late StreamController<QuerySnapshot<Map<String, dynamic>>> controller; // ignore: close_sinks

    StreamSubscription<DocumentSnapshot>? snapshotStreamSubscription;
    controller = StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast(
      onListen: () async {
        // Push cached data first
        controller.add(await query.get(const GetOptions(source: Source.cache)));
        _log('[FirestoreCache] cached data emitted in stream of query: "${query.toString()}"');

        // Then listen to [firestoreCacheField] changes
        snapshotStreamSubscription = firebaseCacheDocRef.snapshots().listen((doc) async {
          // Get server's date
          final serverDateRaw = doc.data()?[firestoreCacheField];

          // Get data from cache or server, providing latest server's date
          final snapshot = await getDocuments(
            query: query,
            firebaseCacheDocRef: firebaseCacheDocRef,
            firestoreCacheField: firestoreCacheField,
            localCacheKey: localCacheKey,
            updateLocalCacheDate: updateLocalCacheDate,
            serverDateRaw: serverDateRaw,
          );

          // Push new value if it's new (from server)
          if (!snapshot.metadata.isFromCache) {
            controller.add(snapshot);
            _log('[FirestoreCache] new server data emitted in stream of query: "${query.toString()}"');
          }
        }, onError: controller.addError);
      },
      onCancel: () => snapshotStreamSubscription?.cancel(),
    );

    return controller.stream;
  }

  /// Whether to fetch documents from server.
  /// Will read latest date from server and compare it to local date,
  /// to check if cache is stale, so it may cost 1 read, except if [serverDateRaw] is provided.
  @visibleForTesting
  static Future<bool> shouldFetchDocuments(
    DocumentReference<Map<String, dynamic>> firebaseCacheDocRef,
    String firestoreCacheField,
    String localCacheKey,
    [dynamic serverDateRaw]
  ) async {
    var shouldFetch = true;
    final prefs = await SharedPreferences.getInstance();
    final dateStr = prefs.getString(localCacheKey);

    if (dateStr != null) {
      final cacheDate = DateTime.parse(dateStr);

      if (serverDateRaw == null) {
        final doc = await firebaseCacheDocRef.get();
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

    _log('[FirestoreCache] cache of "${firebaseCacheDocRef.path}" is ${shouldFetch ? 'stale' : 'up-to-date'}');
    return shouldFetch;
  }
}

enum FirestoreCacheMode {
  /// Read from cache first, or from server if cache is empty or stale.
  /// Will read latest date from server to check if cache is stale, so it may cost 1 read.
  ///
  /// This is the default mode. You are sure to have the latest data available, but it takes some delay and may cost 1 read.
  cacheOrServer,

  /// Read from cache, then update cache from server in background if stale.
  /// If cache is empty, read data from server.
  /// Will read latest date from server to check if cache is stale, so it may cost 1 read.
  ///
  /// This mode is useful if it's not important to get the latest data immediately (usually app will display new data next launch).
  /// This way data will be available very quickly (from cache), and will be updated in background if needed.
  cacheThenServer,

  /// Read from cache only, without any fallbacks.
  ///
  /// This mode is useful if you know device is offline and you want to avoid any delay (returns cache quickly).
  cacheOnly,
}
