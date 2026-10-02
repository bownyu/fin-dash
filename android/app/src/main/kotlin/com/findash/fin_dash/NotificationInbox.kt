package com.findash.fin_dash

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

class NotificationInbox private constructor(context: Context) :
    SQLiteOpenHelper(context, "payment_inbox.db", null, 1) {
    companion object {
        @Volatile private var instance: NotificationInbox? = null
        fun get(context: Context): NotificationInbox = instance ?: synchronized(this) {
            instance ?: NotificationInbox(context.applicationContext).also { instance = it }
        }
    }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE events (id TEXT PRIMARY KEY, payload TEXT NOT NULL, posted_at INTEGER NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    @Synchronized fun put(id: String, payload: JSONObject, postedAt: Long): Boolean {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.rawQuery("SELECT id FROM events WHERE id = ?", arrayOf(id)).use {
                if (it.moveToFirst()) { db.setTransactionSuccessful(); return true }
            }
            if (count() >= 1000) { db.setTransactionSuccessful(); return false }
            val values = ContentValues().apply {
                put("id", id); put("payload", payload.toString()); put("posted_at", postedAt)
            }
            db.insertOrThrow("events", null, values)
            db.setTransactionSuccessful()
            return true
        } finally { db.endTransaction() }
    }
    @Synchronized fun peek(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        readableDatabase.rawQuery("SELECT payload FROM events ORDER BY posted_at, id LIMIT 100", null).use { cursor ->
            while (cursor.moveToNext()) {
                val obj = JSONObject(cursor.getString(0))
                result.add(obj.keys().asSequence().associateWith { key -> obj.opt(key).let { if (it == JSONObject.NULL) null else it } })
            }
        }
        return result
    }
    @Synchronized fun acknowledge(ids: List<String>) {
        val db = writableDatabase
        db.beginTransaction()
        try { ids.forEach { db.delete("events", "id = ?", arrayOf(it)) }; db.setTransactionSuccessful() }
        finally { db.endTransaction() }
    }
    @Synchronized fun count(): Int = readableDatabase.rawQuery("SELECT count(*) FROM events", null).use { it.moveToFirst(); it.getInt(0) }
    @Synchronized fun clear() { writableDatabase.delete("events", null, null) }
}
