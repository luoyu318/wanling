package repository

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
)

// mpDataUser 只造测试用户(同 appid 第二个用户用;mini_program_data.appid 无外键)。
func mpDataUser(t *testing.T, db *sql.DB, tag string) string {
	t.Helper()
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	ownerID, _ := mkMPDeps(t, ur, fr, tag)
	return ownerID
}

// mpDataSeed 注册一个小程序行(appid 挂到真实 owner/file,每 appid 仅一次),返回 ownerID。
func mpDataSeed(t *testing.T, db *sql.DB, tag, appid string) string {
	t.Helper()
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	mpRepo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, tag)
	mp := mpFixture(t, ownerID, appid, 1)
	mp.PackageFileID = fileID
	if err := mpRepo.Create(t.Context(), mp); err != nil {
		t.Fatalf("seed mp: %v", err)
	}
	return ownerID
}

// mpDataDefaultLimits 宽松限额(配额语义由专门用例覆盖)。
func mpDataDefaultLimits() QuotaLimits {
	return QuotaLimits{AppBytes: 20 << 20, AppEntries: 5000, MyBytes: 20 << 20, MyEntries: 5000, MaxValueBytes: 256 << 10}
}

// mpDataJSONPad 生成指定字节数的合法 JSON value(最小 9 字节:{"p": ""} + padding)。
// 输入采用 PG jsonb 规范化格式(": "/", " 分隔),确保写读往返字节一致。
func mpDataJSONPad(t *testing.T, size int) []byte {
	t.Helper()
	if size < 9 {
		t.Fatalf("jsonPad 最小 9 字节,请求 %d", size)
	}
	return []byte(`{"p": "` + strings.Repeat("x", size-9) + `"}`)
}

// 用例 1: 写入 → 读回,value/size_bytes/version=1 往返一致。
func TestMPData_UpsertGet_Roundtrip(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "a", "app-a")
	limits := mpDataDefaultLimits()

	got, err := repo.UpsertEntry(t.Context(), "app-a", ownerID, "default", "k1", []byte(`{"a": 1}`), nil, limits)
	if err != nil {
		t.Fatalf("UpsertEntry: %v", err)
	}
	if got.Version != 1 || got.SizeBytes != int64(len(`{"a": 1}`)) {
		t.Fatalf("version/size 期望 1/8, 实际 %d/%d", got.Version, got.SizeBytes)
	}

	row, err := repo.GetEntry(t.Context(), "app-a", ownerID, "default", "k1")
	if err != nil || row == nil || string(row.Value) != `{"a": 1}` {
		t.Fatalf("GetEntry: err=%v row=%v", err, row)
	}
	if row.ID == 0 || row.Coll != "default" || row.Key != "k1" || row.OwnerID != ownerID {
		t.Errorf("行字段不符: %+v", row)
	}
}

// 用例 2: 同 key 二写 version 自增,size 随新值变更。
func TestMPData_UpsertTwice_VersionIncrements(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "b", "app-b")
	limits := mpDataDefaultLimits()

	if _, err := repo.UpsertEntry(t.Context(), "app-b", ownerID, "default", "k1", []byte(`{"a": 1}`), nil, limits); err != nil {
		t.Fatalf("第一次 UpsertEntry: %v", err)
	}
	got, err := repo.UpsertEntry(t.Context(), "app-b", ownerID, "default", "k1", []byte(`{"ab": 12}`), nil, limits)
	if err != nil {
		t.Fatalf("第二次 UpsertEntry: %v", err)
	}
	if got.Version != 2 || got.SizeBytes != int64(len(`{"ab": 12}`)) {
		t.Fatalf("期望 version=2 size=10, 实际 %d/%d", got.Version, got.SizeBytes)
	}
	row, _ := repo.GetEntry(t.Context(), "app-b", ownerID, "default", "k1")
	if row == nil || row.Version != 2 || string(row.Value) != `{"ab": 12}` {
		t.Fatalf("读回不符: %+v", row)
	}
}

// 用例 3: expectedVersion 与现值不等 → ErrVersionConflict,行保持原样。
func TestMPData_ExpectedVersion_Mismatch(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "c", "app-c")
	limits := mpDataDefaultLimits()

	if _, err := repo.UpsertEntry(t.Context(), "app-c", ownerID, "default", "k1", []byte(`{"a": 1}`), nil, limits); err != nil {
		t.Fatalf("seed UpsertEntry: %v", err)
	}
	wrong := int64(999)
	_, err := repo.UpsertEntry(t.Context(), "app-c", ownerID, "default", "k1", []byte(`{"b": 2}`), &wrong, limits)
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("期望 ErrVersionConflict,实际 %v", err)
	}
	row, _ := repo.GetEntry(t.Context(), "app-c", ownerID, "default", "k1")
	if row == nil || row.Version != 1 || string(row.Value) != `{"a": 1}` {
		t.Fatalf("冲突后行应未变: %+v", row)
	}
}

// 用例 4: expectedVersion 与现值相等 → 成功,version+1。
func TestMPData_ExpectedVersion_Match(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "d", "app-d")
	limits := mpDataDefaultLimits()

	if _, err := repo.UpsertEntry(t.Context(), "app-d", ownerID, "default", "k1", []byte(`{"a": 1}`), nil, limits); err != nil {
		t.Fatalf("seed UpsertEntry: %v", err)
	}
	expected := int64(1)
	got, err := repo.UpsertEntry(t.Context(), "app-d", ownerID, "default", "k1", []byte(`{"b": 2}`), &expected, limits)
	if err != nil {
		t.Fatalf("UpsertEntry: %v", err)
	}
	if got.Version != 2 || string(got.Value) != `{"b": 2}` {
		t.Fatalf("期望 version=2 新值,实际 %d %s", got.Version, got.Value)
	}
}

// 用例 5: 单值超 MaxValueBytes → ErrQuotaExceeded,message 带 "value too large"。
func TestMPData_QuotaExceeded_ValueTooLarge(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "e", "app-e")
	limits := mpDataDefaultLimits()
	limits.MaxValueBytes = 8

	_, err := repo.UpsertEntry(t.Context(), "app-e", ownerID, "default", "k1", mpDataJSONPad(t, 9), nil, limits)
	if !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("期望 ErrQuotaExceeded,实际 %v", err)
	}
	if !strings.Contains(err.Error(), "value too large") {
		t.Fatalf("message 应含 value too large: %v", err)
	}
	if row, _ := repo.GetEntry(t.Context(), "app-e", ownerID, "default", "k1"); row != nil {
		t.Fatalf("超限不应落行")
	}
}

// 用例 6: appid 总量帽(AppBytes)超 → 第二条拒绝。
func TestMPData_QuotaExceeded_AppTotal(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "f", "app-f")
	limits := mpDataDefaultLimits()
	limits.AppBytes = 100

	if _, err := repo.UpsertEntry(t.Context(), "app-f", ownerID, "default", "k1", mpDataJSONPad(t, 60), nil, limits); err != nil {
		t.Fatalf("第一条(60B)应成功: %v", err)
	}
	_, err := repo.UpsertEntry(t.Context(), "app-f", ownerID, "default", "k2", mpDataJSONPad(t, 60), nil, limits)
	if !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("第二条(累计 120B>100)期望 ErrQuotaExceeded,实际 %v", err)
	}
	// 替换语义:原值 60B 缩到 40B → 总量 40 ≤ 100 应放行
	if _, err := repo.UpsertEntry(t.Context(), "app-f", ownerID, "default", "k1", mpDataJSONPad(t, 40), nil, limits); err != nil {
		t.Fatalf("替换缩减后(40B)应成功: %v", err)
	}
}

// 用例 7: 用户子帽(MyBytes)按 owner 独立计:A 的占用不吃 B 的帽,只拦 B 自己累计超。
func TestMPData_QuotaExceeded_UserSub(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerA := mpDataSeed(t, db, "g1", "app-g")
	ownerB := mpDataUser(t, db, "g2")
	limits := mpDataDefaultLimits()
	limits.MyBytes = 100

	if _, err := repo.UpsertEntry(t.Context(), "app-g", ownerA, "default", "k1", mpDataJSONPad(t, 60), nil, limits); err != nil {
		t.Fatalf("A 第一条(60B)应成功: %v", err)
	}
	// A 已占 60B;若子帽不按用户隔离,B 此处即 120>100 被拒
	if _, err := repo.UpsertEntry(t.Context(), "app-g", ownerB, "default", "k1", mpDataJSONPad(t, 60), nil, limits); err != nil {
		t.Fatalf("B 第一条(用户隔离,60B≤100)应成功: %v", err)
	}
	// B 自己累计 60+60=120 > 100 → 拒
	_, err := repo.UpsertEntry(t.Context(), "app-g", ownerB, "default", "k2", mpDataJSONPad(t, 60), nil, limits)
	if !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("B 第二条(累计 120B>100)期望 ErrQuotaExceeded,实际 %v", err)
	}
}

// 用例 8: 条目数帽(AppEntries)超 → 第三条拒绝。
func TestMPData_QuotaExceeded_Entries(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "h", "app-h")
	limits := mpDataDefaultLimits()
	limits.AppEntries = 2

	for _, k := range []string{"k1", "k2"} {
		if _, err := repo.UpsertEntry(t.Context(), "app-h", ownerID, "default", k, []byte(`{"a": 1}`), nil, limits); err != nil {
			t.Fatalf("前两条应成功 %s: %v", k, err)
		}
	}
	_, err := repo.UpsertEntry(t.Context(), "app-h", ownerID, "default", "k3", []byte(`{"a": 1}`), nil, limits)
	if !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("第三条(AppEntries=2)期望 ErrQuotaExceeded,实际 %v", err)
	}
}

// 用例 9: 用户隔离 — A 的行 B 读不到;B 写同 key 各自成行互不影响。
func TestMPData_UserIsolation(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerA := mpDataSeed(t, db, "i1", "app-i")
	ownerB := mpDataUser(t, db, "i2")
	limits := mpDataDefaultLimits()

	if _, err := repo.UpsertEntry(t.Context(), "app-i", ownerA, "default", "k1", []byte(`{"owner": "a"}`), nil, limits); err != nil {
		t.Fatalf("A 写入: %v", err)
	}
	if row, err := repo.GetEntry(t.Context(), "app-i", ownerB, "default", "k1"); err != nil || row != nil {
		t.Fatalf("B 读 A 的行应 nil,nil,实际 %v %v", row, err)
	}
	// B 写同 key:独立新行,version 从 1 起,不动 A 的行
	got, err := repo.UpsertEntry(t.Context(), "app-i", ownerB, "default", "k1", []byte(`{"owner": "b"}`), nil, limits)
	if err != nil {
		t.Fatalf("B 写同 key: %v", err)
	}
	if got.Version != 1 || string(got.Value) != `{"owner": "b"}` {
		t.Fatalf("B 行应为独立 v1: %+v", got)
	}
	rowA, _ := repo.GetEntry(t.Context(), "app-i", ownerA, "default", "k1")
	if rowA == nil || rowA.Version != 1 || string(rowA.Value) != `{"owner": "a"}` {
		t.Fatalf("A 行不应被 B 影响: %+v", rowA)
	}
}

// 用例 10a: 删除不存在的键 → nil,nil。
func TestMPData_Delete_Missing_ReturnsNilNil(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "j", "app-j")

	row, err := repo.DeleteEntry(t.Context(), "app-j", ownerID, "default", "nope", nil)
	if err != nil || row != nil {
		t.Fatalf("期望 nil,nil,实际 %v %v", row, err)
	}
}

// 用例 10b: 删除语义 + version 校验 — 不符拒删,相符返回被删行,已删再删 nil,nil。
func TestMPData_Delete_WithVersion(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "k", "app-k")
	limits := mpDataDefaultLimits()

	if _, err := repo.UpsertEntry(t.Context(), "app-k", ownerID, "default", "k1", []byte(`{"a": 1}`), nil, limits); err != nil {
		t.Fatalf("seed: %v", err)
	}
	wrong := int64(999)
	if _, err := repo.DeleteEntry(t.Context(), "app-k", ownerID, "default", "k1", &wrong); !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("version 不符期望 ErrVersionConflict,实际 %v", err)
	}
	if row, _ := repo.GetEntry(t.Context(), "app-k", ownerID, "default", "k1"); row == nil {
		t.Fatalf("冲突删除不应删行")
	}

	expected := int64(1)
	deleted, err := repo.DeleteEntry(t.Context(), "app-k", ownerID, "default", "k1", &expected)
	if err != nil {
		t.Fatalf("DeleteEntry: %v", err)
	}
	if deleted == nil || deleted.Version != 1 || string(deleted.Value) != `{"a": 1}` {
		t.Fatalf("被删行不符: %+v", deleted)
	}
	if row, _ := repo.GetEntry(t.Context(), "app-k", ownerID, "default", "k1"); row != nil {
		t.Fatalf("删除后应读不到")
	}
	// 无条件再删(已不存在) → nil,nil
	if row, err := repo.DeleteEntry(t.Context(), "app-k", ownerID, "default", "k1", nil); err != nil || row != nil {
		t.Fatalf("重复删除期望 nil,nil,实际 %v %v", row, err)
	}
}

// 用例 11: prefix 过滤 + cursor 翻页 + limit;nextCursor 末轮空。
func TestMPData_ListEntries_PrefixCursorLimit(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerID := mpDataSeed(t, db, "l", "app-l")
	limits := mpDataDefaultLimits()

	for _, k := range []string{"k1", "k2", "k3", "k4", "k5", "x1"} {
		if _, err := repo.UpsertEntry(t.Context(), "app-l", ownerID, "default", k, []byte(`{"k":"`+k+`"}`), nil, limits); err != nil {
			t.Fatalf("seed %s: %v", k, err)
		}
	}

	// 三轮翻页:limit=2, prefix=k 滤掉 x1
	wantPages := [][]string{{"k1", "k2"}, {"k3", "k4"}, {"k5"}}
	cursor := ""
	for i, want := range wantPages {
		rows, next, err := repo.ListEntries(t.Context(), "app-l", ownerID, "default", "k", cursor, 2)
		if err != nil {
			t.Fatalf("第 %d 轮 ListEntries: %v", i+1, err)
		}
		keys := make([]string, len(rows))
		for j, r := range rows {
			keys[j] = r.Key
		}
		if strings.Join(keys, ",") != strings.Join(want, ",") {
			t.Fatalf("第 %d 轮期望 %v,实际 %v", i+1, want, keys)
		}
		lastRound := i == len(wantPages)-1
		if (next == "") != lastRound {
			t.Fatalf("第 %d 轮 nextCursor 期望空=%v,实际 %q", i+1, lastRound, next)
		}
		cursor = next
	}
	if cursor != "" {
		t.Fatalf("末轮 nextCursor 应空,实际 %q", cursor)
	}
}

// 用例 12: Stats 双层聚合 — AppBytes/AppEntries 为 appid 总量,MyBytes/MyEntries 为指定用户子量。
func TestMPData_Stats(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerA := mpDataSeed(t, db, "m1", "app-m")
	ownerB := mpDataUser(t, db, "m2")
	limits := mpDataDefaultLimits()

	for _, k := range []string{"k1", "k2"} {
		if _, err := repo.UpsertEntry(t.Context(), "app-m", ownerA, "default", k, mpDataJSONPad(t, 60), nil, limits); err != nil {
			t.Fatalf("A seed %s: %v", k, err)
		}
	}
	if _, err := repo.UpsertEntry(t.Context(), "app-m", ownerB, "default", "k1", mpDataJSONPad(t, 30), nil, limits); err != nil {
		t.Fatalf("B seed: %v", err)
	}

	st, err := repo.Stats(t.Context(), "app-m", ownerB)
	if err != nil {
		t.Fatalf("Stats: %v", err)
	}
	if st.AppBytes != 150 || st.AppEntries != 3 || st.MyBytes != 30 || st.MyEntries != 1 {
		t.Fatalf("期望 App 150B/3 + My(B) 30B/1,实际 %+v", st)
	}
}

// 用例 13: DeleteAllForApp 只清目标 appid,他 appid 数据保留。
func TestMPData_DeleteAllForApp(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramDataRepo(db)
	ownerA := mpDataSeed(t, db, "n1", "app-n1")
	ownerB := mpDataSeed(t, db, "n2", "app-n2")
	limits := mpDataDefaultLimits()

	for _, k := range []string{"k1", "k2"} {
		if _, err := repo.UpsertEntry(t.Context(), "app-n1", ownerA, "default", k, []byte(`{"a": 1}`), nil, limits); err != nil {
			t.Fatalf("app-n1 seed %s: %v", k, err)
		}
	}
	if _, err := repo.UpsertEntry(t.Context(), "app-n2", ownerB, "default", "k1", []byte(`{"b":1}`), nil, limits); err != nil {
		t.Fatalf("app-n2 seed: %v", err)
	}

	n, err := repo.DeleteAllForApp(t.Context(), "app-n1")
	if err != nil || n != 2 {
		t.Fatalf("DeleteAllForApp 期望 2,实际 %d %v", n, err)
	}
	if row, _ := repo.GetEntry(t.Context(), "app-n1", ownerA, "default", "k1"); row != nil {
		t.Fatalf("app-n1 应已清空")
	}
	if row, err := repo.GetEntry(t.Context(), "app-n2", ownerB, "default", "k1"); err != nil || row == nil {
		t.Fatalf("app-n2 应保留: %v %v", row, err)
	}
	if n, _ := repo.DeleteAllForApp(t.Context(), "app-n1"); n != 0 {
		t.Fatalf("空 appid 再删应 0,实际 %d", n)
	}
}
