DROP PROCEDURE IF EXISTS fm_update_rand;
DELIMITER //
CREATE PROCEDURE fm_update_rand(IN tbl VARCHAR(255), IN steps INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE sidv VARCHAR(50);
  WHILE i < steps DO
    SELECT sid INTO sidv FROM hot_sids ORDER BY RAND() LIMIT 1;
    SET @q = CONCAT('UPDATE ', tbl, ' SET close = COALESCE(close,0)+1 WHERE sid = ''', sidv, '''');
    PREPARE st FROM @q; EXECUTE st; DEALLOCATE PREPARE st;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;