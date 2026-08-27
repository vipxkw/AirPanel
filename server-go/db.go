package main

import (
	"database/sql"
	"encoding/json"
	"time"

	_ "modernc.org/sqlite"
)

// DB 封装 SQLite 数据访问（设备、任务记录）
type DB struct {
	sql *sql.DB
}

func openDB(path string) (*DB, error) {
	sqlDB, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(1) // SQLite 单写者
	if err := sqlDB.Ping(); err != nil {
		return nil, err
	}
	db := &DB{sql: sqlDB}
	if err := db.init(); err != nil {
		return nil, err
	}
	return db, nil
}

func (d *DB) init() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS devices (
			imei       TEXT PRIMARY KEY,
			phone      TEXT DEFAULT '',
			name       TEXT DEFAULT '',
			connected  INTEGER DEFAULT 0,
			last_seen  INTEGER DEFAULT 0,
			first_seen INTEGER DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS tasks (
			id          INTEGER PRIMARY KEY AUTOINCREMENT,
			task_id     TEXT DEFAULT '',
			imei        TEXT DEFAULT '',
			task        TEXT DEFAULT '',
			params      TEXT DEFAULT '',
			result      TEXT DEFAULT '',
			error       TEXT DEFAULT '',
			status      TEXT DEFAULT 'pending',
			created_at  INTEGER DEFAULT 0,
			finished_at INTEGER DEFAULT 0
		)`,
	}
	for _, s := range stmts {
		if _, err := d.sql.Exec(s); err != nil {
			return err
		}
	}
	return nil
}

// upsertDevice 写入或更新设备记录（在线状态 + 最近活跃时间）
func (d *DB) upsertDevice(imei, phone string, connected bool, lastSeen int64) error {
	_, err := d.sql.Exec(
		`INSERT INTO devices (imei, phone, connected, last_seen, first_seen)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(imei) DO UPDATE SET
		   phone = CASE WHEN ? <> '' THEN ? ELSE phone END,
		   connected = ?,
		   last_seen = ?`,
		imei, phone, b2i(connected), lastSeen, lastSeen,
		phone, phone, b2i(connected), lastSeen,
	)
	return err
}

// listDevices 返回设备列表
func (d *DB) listDevices() ([]Device, error) {
	rows, err := d.sql.Query(`SELECT imei, phone, name, connected, last_seen, first_seen FROM devices`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out = make([]Device, 0)
	for rows.Next() {
		var dev Device
		var connected int
		if err := rows.Scan(&dev.IMEI, &dev.Phone, &dev.Name, &connected, &dev.LastSeen, &dev.FirstSeen); err != nil {
			return nil, err
		}
		dev.Connected = connected != 0
		out = append(out, dev)
	}
	return out, rows.Err()
}

// updateDeviceName 设置设备备注（name，空串表示清除）
func (d *DB) updateDeviceName(imei, name string) error {
	_, err := d.sql.Exec(`UPDATE devices SET name = ? WHERE imei = ?`, name, imei)
	return err
}

// recordTask 记录任务执行记录
func (d *DB) recordTask(rec TaskRecord) error {
	_, err := d.sql.Exec(
		`INSERT INTO tasks (task_id, imei, task, params, result, error, status, created_at, finished_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.TaskID, rec.IMEI, rec.Task, rec.Params, rec.Result, rec.Error, rec.Status,
		rec.CreatedAt, rec.FinishedAt,
	)
	return err
}

// recentTasks 返回最近任务记录（关联设备备注名，用于展示）
func (d *DB) recentTasks(limit int) ([]TaskRecord, error) {
	rows, err := d.sql.Query(
		`SELECT t.task_id, t.imei, t.task, t.params, t.result, t.error, t.status, t.created_at, t.finished_at, d.name
		 FROM tasks t LEFT JOIN devices d ON d.imei = t.imei
		 ORDER BY t.id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out = make([]TaskRecord, 0)
	for rows.Next() {
		var rec TaskRecord
		if err := rows.Scan(&rec.TaskID, &rec.IMEI, &rec.Task, &rec.Params, &rec.Result,
			&rec.Error, &rec.Status, &rec.CreatedAt, &rec.FinishedAt, &rec.DeviceName); err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

// deleteTasks 删除任务记录。days > 0 时只删除距今超过 days 天的旧日志（保留近 days 天）；days <= 0 时删除全部。
// 返回被删除的记录条数。
func (d *DB) deleteTasks(days int) (int64, error) {
	if days > 0 {
		cutoff := time.Now().Add(-time.Duration(days) * 24 * time.Hour).Unix()
		res, err := d.sql.Exec(`DELETE FROM tasks WHERE created_at < ?`, cutoff)
		if err != nil {
			return 0, err
		}
		return res.RowsAffected()
	}
	res, err := d.sql.Exec(`DELETE FROM tasks`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// jsonBytes 用于日志/持久化的辅助
func jsonBytes(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
