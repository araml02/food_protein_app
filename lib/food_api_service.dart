import 'dart:convert';

import 'package:http/http.dart' as http;

class FoodApiService {
  FoodApiService({http.Client? client}) : _client = client ?? http.Client();

  static const String _userAgent = 'GainSaverApp - Flutter';

  final http.Client _client;

  Future<Map<String, dynamic>?> fetchProductFromOFF(String barcode) async {
    final cleanedBarcode = barcode.trim();
    if (cleanedBarcode.isEmpty) return null;

    final uri = Uri.parse(
      'https://world.openfoodfacts.org/api/v2/product/$cleanedBarcode.json',
    );

    final response = await _client.get(
      uri,
      headers: const {'User-Agent': _userAgent},
    );

    if (response.statusCode != 200) {
      throw Exception('OFF request failed with status ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['status'] == 0) return null;

    final productData = decoded['product'];
    if (productData is! Map) return null;

    final product = Map<String, dynamic>.from(productData);
    final nutrimentsData = product['nutriments'];
    final nutriments = nutrimentsData is Map
        ? Map<String, dynamic>.from(nutrimentsData)
        : <String, dynamic>{};

    return {
      'name': (product['product_name'] ?? '').toString(),
      'brand': (product['brands'] ?? '').toString(),
      'p': _toNum(nutriments['proteins_100g']) ?? 0,
      'kcal': _toNum(nutriments['energy-kcal_100g']) ?? 0,
      'code': cleanedBarcode,
    };
  }

  Future<List<Map<String, dynamic>>> searchExternalProducts(
    String query,
  ) async {
    final cleanedQuery = query.trim();
    if (cleanedQuery.isEmpty) return [];

    final uri = Uri.https('world.openfoodfacts.org', '/cgi/search.pl', {
      'search_terms': cleanedQuery,
      'action': 'process',
      'json': '1',
      'page_size': '20',
      'fields': 'product_name,brands,nutriments,code,image_url',
    });

    final response = await _client.get(
      uri,
      headers: const {'User-Agent': _userAgent},
    );

    if (response.statusCode != 200) {
      throw Exception('OFF search failed with status ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return [];

    final rawProducts = decoded['products'];
    if (rawProducts is! List) return [];

    final results = rawProducts.whereType<Map>().map((raw) {
      final product = Map<String, dynamic>.from(raw);
      final nutrimentsData = product['nutriments'];
      final nutriments = nutrimentsData is Map
          ? Map<String, dynamic>.from(nutrimentsData)
          : <String, dynamic>{};

      return <String, dynamic>{
        'name': (product['product_name'] ?? '').toString(),
        'brand': (product['brands'] ?? '').toString(),
        'p': _toNum(nutriments['proteins_100g']) ?? 0,
        'kcal': _toNum(nutriments['energy-kcal_100g']) ?? 0,
        'code': (product['code'] ?? '').toString(),
      };
    }).toList();

    return results;
  }

  num? _toNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    if (value is String) return num.tryParse(value.replaceAll(',', '.'));
    return null;
  }

  void dispose() {
    _client.close();
  }
}
