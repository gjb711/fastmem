-- FASTMEM vs MEMORY vs InnoDB benchmark schema (MariaDB 12.x)
-- 7000-row K-line table on each engine + 100 hot rows + driver procs.

CREATE DATABASE IF NOT EXISTS fmtest;
USE fmtest;

DROP TABLE IF EXISTS hot_sids;
DROP TABLE IF EXISTS inn_kline;
DROP TABLE IF EXISTS mm_kline;
DROP TABLE IF EXISTS fm_kline;
DROP TABLE IF EXISTS kline_stage;
DROP PROCEDURE IF EXISTS fm_writer;
DROP PROCEDURE IF EXISTS fm_reader;

CREATE TABLE kline_stage (
  sid   VARCHAR(50) NOT NULL PRIMARY KEY,
  close DECIMAL(19,4) NOT NULL
) ENGINE=InnoDB;

-- MariaDB's built-in sequence table avoids the recursive-iteration limit.
INSERT INTO kline_stage
SELECT CONCAT('K', LPAD(seq,8,'0')), 1 + seq*0.001 FROM seq_1_to_7000;

CREATE TABLE fm_kline  ENGINE=FASTMEM AS SELECT * FROM kline_stage;
CREATE TABLE mm_kline  ENGINE=MEMORY  AS SELECT * FROM kline_stage;
CREATE TABLE inn_kline ENGINE=InnoDB  AS SELECT * FROM kline_stage;

CREATE TABLE hot_sids (sid VARCHAR(50) NOT NULL PRIMARY KEY) ENGINE=MEMORY;
INSERT INTO hot_sids SELECT sid FROM fm_kline ORDER BY RAND() LIMIT 100;

DELIMITER //
-- writer: n UPDATEs of +1 on a random hot row of the given table.
-- The random sid is resolved in its own statement: `UPDATE ... WHERE
-- sid=(SELECT ... ORDER BY RAND() ...)` would be re-evaluated per
-- candidate row by the 12.1.2 optimizer and swamp the engine delta.
CREATE PROCEDURE fm_writer(IN tbl VARCHAR(20), IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < n DO
    SET @sid = (SELECT sid FROM hot_sids ORDER BY RAND() LIMIT 1);
    SET @w = CONCAT('UPDATE ', tbl, ' SET close=close+1 WHERE sid=''', @sid, '''');
    PREPARE s FROM @w;
    EXECUTE s;
    DEALLOCATE PREPARE s;
    SET i = i + 1;
  END WHILE;
END//
-- reader: n full-table SUM scans
CREATE PROCEDURE fm_reader(IN tbl VARCHAR(20), IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  SET @r = CONCAT('SELECT SUM(close) FROM ', tbl);
  PREPARE s FROM @r;
  WHILE i < n DO
    EXECUTE s;
    SET i = i + 1;
  END WHILE;
  DEALLOCATE PREPARE s;
END//
DELIMITER ;
