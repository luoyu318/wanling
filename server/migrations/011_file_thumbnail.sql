-- 011_file_thumbnail.sql
-- files 表加缩略图字段：上传图片时同步生成 600px 长边缩略图（WebP）。
-- - thumbnail_path：缩略图存储路径，可空（存量图片 / 非图片文件为 NULL，前端 ?thumb=1 降级原图）
-- - width / height：原图像素尺寸，生成缩略图时已知（前端可用作占位防抖）
ALTER TABLE files ADD COLUMN thumbnail_path VARCHAR(512);
ALTER TABLE files ADD COLUMN width INT;
ALTER TABLE files ADD COLUMN height INT;
