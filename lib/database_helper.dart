import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'eiwit_app.db');
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE products (
        code TEXT PRIMARY KEY,
        name TEXT,
        brand TEXT,
        p REAL,
        c REAL,
        f REAL,
        kcal REAL
      )
    ''');
  }

  // Deze functie draai je één keer bij de eerste start van de app
  Future<void> importJsonIfNeeded() async {
    Database db = await database;
    var count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM products'));
    
    if (count == 0) {
      print("Database is leeg. Import starten uit JSON (geduld aub)...");
      final String response = await rootBundle.loadString('assets/eiwit_bijbel.json');
      final lines = response.split('\n');
      
      Batch batch = db.batch();
      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        var p = json.decode(line);
        batch.insert('products', {
          'code': p['code'].toString(),
          'name': p['name'],
          'brand': p['brand'],
          'p': p['p'],
          'c': p['c'],
          'f': p['f'],
          'kcal': p['kcal']
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      print("Import voltooid!");
    }
  }

  // Future<List<Map<String, dynamic>>> searchProducts(String query) async {
  //   Database db = await database;
  //   // We zoeken in de index, dit is milliseconden-werk
  //   return await db.query(
  //     'products',
  //     where: 'name LIKE ? OR code = ?',
  //     whereArgs: ['%$query%', query],
  //     limit: 50,
  //   );
  // }

  Future<List<Map<String, dynamic>>> searchProducts(String query) async {
  Database db = await database;
  
  // We voegen de harde eis 'kcal > 0' toe aan de zoekopdracht
  return await db.query(
    'products',
    where: '(name LIKE ? OR code = ?) AND kcal > 0',
    whereArgs: ['%$query%', query],
    limit: 50,
  );
}



}