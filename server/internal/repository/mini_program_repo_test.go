package repository

import (
	"strconv"
	"testing"

	"github.com/google/uuid"
	"github.com/wanling/server/internal/model"
)

func mpFixture(t *testing.T, ownerID, appid string, version int) *model.MiniProgram {
	t.Helper()
	return &model.MiniProgram{
		ID:            uuid.NewString(),
		Appid:         appid,
		OwnerID:       ownerID,
		Name:          "测试小程序",
		Version:       version,
		ManifestJSON:  []byte(`{"appid":"` + appid + `","name":"测试小程序","version":` + strconv.Itoa(version) + `,"entry":"index.html","permissions":["wanling.api"]}`),
		PackageFileID: uuid.NewString(),
		SHA256:        "aaaa",
		Size:          123,
		Status:        "private",
	}
}

// 建测试用户与 files 记录,返回 (userID, fileID)。
func mkMPDeps(t *testing.T, repo *UserRepo, fileRepo *FileRepo, tag string) (string, string) {
	t.Helper()
	user, err := repo.Create(t.Context(), uniqueShortName(t, "mp"+tag), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	// files 表 owner 外键指向 users;包记录对测试仅占位
	f, err := fileRepo.Create(t.Context(), CreateFileParams{
		OwnerID: user.ID, Filename: tag + ".zip", MimeType: "application/zip",
		Size: 123, StoragePath: "mp/" + tag + ".zip",
	})
	if err != nil {
		t.Fatalf("Create file: %v", err)
	}
	return user.ID, f.ID
}

func TestMiniProgramRepo_Create_GetByID(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, "a")
	mp := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	mp.PackageFileID = fileID

	if err := repo.Create(t.Context(), mp); err != nil {
		t.Fatalf("Create: %v", err)
	}
	got, err := repo.GetByID(t.Context(), mp.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if got.Appid != mp.Appid || got.Status != "private" || got.OwnerID != ownerID {
		t.Errorf("字段不符: %+v", got)
	}
}

func TestMiniProgramRepo_GetByID_Missing_ReturnsNilNil(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewMiniProgramRepo(db)
	got, err := repo.GetByID(t.Context(), uuid.NewString())
	if err != nil || got != nil {
		t.Errorf("期望 nil,nil,实际 %v %v", got, err)
	}
}

func TestMiniProgramRepo_ListVisibleTo_PublishedOrOwner(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, "b")
	otherID, _ := mkMPDeps(t, ur, fr, "c")

	priv := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	priv.PackageFileID = fileID
	pub := mpFixture(t, otherID, "mp-"+uuid.NewString()[:8], 1)
	pub.PackageFileID = fileID
	for _, mp := range []*model.MiniProgram{priv, pub} {
		if err := repo.Create(t.Context(), mp); err != nil {
			t.Fatalf("Create: %v", err)
		}
	}
	if err := repo.UpdateStatus(t.Context(), pub.ID, "published"); err != nil {
		t.Fatalf("UpdateStatus: %v", err)
	}

	// owner 看到自己的 private + 别人的 published
	visible, err := repo.ListVisibleTo(t.Context(), ownerID)
	if err != nil {
		t.Fatalf("ListVisibleTo: %v", err)
	}
	ids := map[string]bool{}
	for _, m := range visible {
		ids[m.ID] = true
	}
	if !ids[priv.ID] || !ids[pub.ID] {
		t.Errorf("owner 可见集不符: %v", ids)
	}

	// 陌生人看不到 private
	visible2, _ := repo.ListVisibleTo(t.Context(), otherID)
	for _, m := range visible2 {
		if m.ID == priv.ID {
			t.Errorf("他人 private 不应可见")
		}
	}
}

func TestMiniProgramRepo_ReplaceVersion_ResetsToPrivate(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, "d")
	mp := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	mp.PackageFileID = fileID
	if err := repo.Create(t.Context(), mp); err != nil {
		t.Fatalf("Create: %v", err)
	}
	_ = repo.UpdateStatus(t.Context(), mp.ID, "published")

	_, fileID2 := mkMPDeps(t, ur, fr, "e") // 复用流程建新 user+file,取新 fileID
	err := repo.ReplaceVersion(t.Context(), mp.ID, ReplaceVersionParams{
		Name:          "测试小程序v2",
		Version:       2,
		ManifestJSON:  []byte(`{"appid":"x","version":2}`),
		PackageFileID: fileID2,
		SHA256:        "bbbb",
		Size:          456,
	})
	if err != nil {
		t.Fatalf("ReplaceVersion: %v", err)
	}
	got, _ := repo.GetByID(t.Context(), mp.ID)
	if got.Version != 2 || got.Status != "private" || got.SHA256 != "bbbb" {
		t.Errorf("替换后状态不符: %+v", got)
	}
}

func TestMiniProgramRepo_UpdateSignature(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, "s")
	priv := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	priv.PackageFileID = fileID
	pub := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	pub.PackageFileID = fileID
	for _, mp := range []*model.MiniProgram{priv, pub} {
		if err := repo.Create(t.Context(), mp); err != nil {
			t.Fatalf("Create: %v", err)
		}
	}
	if err := repo.UpdateStatus(t.Context(), pub.ID, "published"); err != nil {
		t.Fatalf("UpdateStatus: %v", err)
	}

	// 未签时:Signature 空串;published 未签在 missing 列表;private 不在
	got, err := repo.GetByID(t.Context(), pub.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if got.Signature != "" {
		t.Errorf("未签时 Signature 应为空,实际 %q", got.Signature)
	}
	missing, err := repo.ListPublishedMissingSignature(t.Context())
	if err != nil {
		t.Fatalf("ListPublishedMissingSignature: %v", err)
	}
	ids := map[string]bool{}
	for _, m := range missing {
		ids[m.ID] = true
	}
	if !ids[pub.ID] {
		t.Errorf("published 未签应在 missing 列表: %v", ids)
	}
	if ids[priv.ID] {
		t.Errorf("private 不应在 missing 列表: %v", ids)
	}

	// 签名后:Signature 回读一致;签后不在 missing 列表
	if err := repo.UpdateSignature(t.Context(), pub.ID, "deadbeef"); err != nil {
		t.Fatalf("UpdateSignature: %v", err)
	}
	got, err = repo.GetByID(t.Context(), pub.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID 签后: %v %v", got, err)
	}
	if got.Signature != "deadbeef" {
		t.Errorf("签后 Signature 应为 deadbeef,实际 %q", got.Signature)
	}
	missing, err = repo.ListPublishedMissingSignature(t.Context())
	if err != nil {
		t.Fatalf("ListPublishedMissingSignature 签后: %v", err)
	}
	for _, m := range missing {
		if m.ID == pub.ID {
			t.Errorf("published 签后不应在 missing 列表")
		}
	}
}

// TestMiniProgramRepo_ListAll_WithOwnerUsername admin 全量列表:三状态全含,
// 带 owner username(JOIN users),updated_at 倒序。
func TestMiniProgramRepo_ListAll_WithOwnerUsername(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	owner, err := ur.Create(t.Context(), uniqueShortName(t, "mpla"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	f, err := fr.Create(t.Context(), CreateFileParams{
		OwnerID: owner.ID, Filename: "la.zip", MimeType: "application/zip",
		Size: 123, StoragePath: "mp/la.zip",
	})
	if err != nil {
		t.Fatalf("Create file: %v", err)
	}

	// 造三个不同状态:Create 落 private,published/disabled 经 UpdateStatus 流转
	mps := map[string]*model.MiniProgram{}
	for _, st := range []string{"private", "published", "disabled"} {
		mp := mpFixture(t, owner.ID, "mp-"+uuid.NewString()[:8], 1)
		mp.PackageFileID = f.ID
		if err := repo.Create(t.Context(), mp); err != nil {
			t.Fatalf("Create %s: %v", st, err)
		}
		if st != "private" {
			if err := repo.UpdateStatus(t.Context(), mp.ID, st); err != nil {
				t.Fatalf("UpdateStatus %s: %v", st, err)
			}
		}
		mps[st] = mp
	}

	got, err := repo.ListAll(t.Context())
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	if len(got) < 3 {
		t.Fatalf("应至少 3 条,实际 %d", len(got))
	}
	statusByID := map[string]string{}
	for _, it := range got {
		if it.OwnerUsername != owner.Username {
			t.Fatalf("owner_username 应为 %q,实际 %q", owner.Username, it.OwnerUsername)
		}
		statusByID[it.ID] = it.Status
	}
	for _, st := range []string{"private", "published", "disabled"} {
		if gotSt := statusByID[mps[st].ID]; gotSt != st {
			t.Fatalf("记录 %s 状态应为 %s,实际 %q", mps[st].ID, st, gotSt)
		}
	}
	for i := 1; i < len(got); i++ {
		if got[i-1].UpdatedAt.Before(got[i].UpdatedAt) {
			t.Fatalf("应 updated_at 倒序")
		}
	}
}

func TestMiniProgramRepo_DeletePrivate_OnlyOwnPrivate(t *testing.T) {
	db := SetupTestDB(t)
	ur, fr := NewUserRepo(db), NewFileRepo(db)
	repo := NewMiniProgramRepo(db)
	ownerID, fileID := mkMPDeps(t, ur, fr, "f")
	otherID, _ := mkMPDeps(t, ur, fr, "g")
	mp := mpFixture(t, ownerID, "mp-"+uuid.NewString()[:8], 1)
	mp.PackageFileID = fileID
	_ = repo.Create(t.Context(), mp)

	// 非 owner 删不掉
	n, err := repo.DeletePrivate(t.Context(), mp.ID, otherID)
	if err != nil || n != 0 {
		t.Errorf("非 owner 应删 0 行,实际 %d %v", n, err)
	}
	// published 删不掉
	_ = repo.UpdateStatus(t.Context(), mp.ID, "published")
	n, _ = repo.DeletePrivate(t.Context(), mp.ID, ownerID)
	if n != 0 {
		t.Errorf("published 应删 0 行,实际 %d", n)
	}
	// private 自己删得掉
	_ = repo.UpdateStatus(t.Context(), mp.ID, "private")
	n, err = repo.DeletePrivate(t.Context(), mp.ID, ownerID)
	if err != nil || n != 1 {
		t.Errorf("应删 1 行,实际 %d %v", n, err)
	}
}
