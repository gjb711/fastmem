#!/bin/bash
# Three-engine benchmark, run INSIDE the fastmem-server container
# (server already exposes FASTMEM via --plugin-load-add).
# Usage: docker exec <ctr> bash /bench/bench.sh
set -uo pipefail
PW="${MARIADB_ROOT_PASSWORD:-bench}"
M() { mariadb -uroot -p"$PW" -N -B "$@"; }

# wait for the server
for i in $(seq 1 120); do
  mariadb-admin -uroot -p"$PW" ping >/dev/null 2>&1 && break; sleep 1
done

echo "=============================================================="
echo " FASTMEM vs MEMORY vs InnoDB"
echo " server: $(M -e 'SELECT VERSION()') | $(uname -m), $(nproc) CPUs"
echo "=============================================================="
M -e "SHOW ENGINES" | awk '$1=="FASTMEM"||$1=="MEMORY"||$1=="InnoDB"{print "engine: "$1" "$2}'

M -e "CREATE DATABASE IF NOT EXISTS fmtest"
mariadb -uroot -p"$PW" < /bench/bench.sql
echo "rows: $(M -e 'SELECT COUNT(*) FROM fmtest.fm_kline')"

declare -A BASE
for t in fm_kline mm_kline inn_kline; do BASE[$t]=$(M -e "SELECT SUM(close) FROM fmtest.$t"); done
echo "baseline SUM(close) fm/mm/inn = ${BASE[fm_kline]} / ${BASE[mm_kline]} / ${BASE[inn_kline]}"

check() { # table before expect_delta
  local t=$1 before=$2 delta=$3
  local after d verdict
  after=$(M -e "SELECT SUM(close) FROM fmtest.$t")
  d=$(echo "$after - $before" | bc)
  verdict=PASS
  [ "$d" != "$delta" ] && verdict="FAIL(exp $delta)"
  echo "  [sum] $t delta=$d -> $verdict"
}

echo ""
echo "--- A: single connection, 2000 updates (random hot row) ---"
for t in fm_kline mm_kline inn_kline; do
  s=$(date +%s)
  M -e "CALL fmtest.fm_writer('$t',2000)"
  e=$(date +%s)
  echo "A $t  $(($e-$s))s"; check "$t" "${BASE[$t]}" 2000
  BASE[$t]=$(M -e "SELECT SUM(close) FROM fmtest.$t")
done

echo ""
echo "--- B: 8 concurrent x 2000 updates ---"
for t in fm_kline mm_kline inn_kline; do
  s=$(date +%s)
  for j in 1 2 3 4 5 6 7 8; do
    ( mariadb -uroot -p"$PW" -N -B -e "CALL fmtest.fm_writer('$t',2000)" >/dev/null 2>&1 ) &
  done
  wait
  e=$(date +%s)
  echo "B $t  $(($e-$s))s"; check "$t" "${BASE[$t]}" 16000
  BASE[$t]=$(M -e "SELECT SUM(close) FROM fmtest.$t")
done

echo ""
echo "--- C: 8 writers x300 + 4 readers x300 (concurrent) ---"
for t in fm_kline mm_kline inn_kline; do
  s=$(date +%s)
  for j in 1 2 3 4 5 6 7 8; do
    ( mariadb -uroot -p"$PW" -N -B -e "CALL fmtest.fm_writer('$t',300)" >/dev/null 2>&1 ) &
  done
  for j in 1 2 3 4; do
    ( mariadb -uroot -p"$PW" -N -B -e "CALL fmtest.fm_reader('$t',300)" >/dev/null 2>&1 ) &
  done
  wait
  e=$(date +%s)
  echo "C $t  $(($e-$s))s"; check "$t" "${BASE[$t]}" 2400
  BASE[$t]=$(M -e "SELECT SUM(close) FROM fmtest.$t")
done

echo ""
echo "--- D: 8 writers x500, readers {0,4,8} x500 ---"
for R in 0 4 8; do
  for t in fm_kline mm_kline inn_kline; do
    s=$(date +%s)
    for j in 1 2 3 4 5 6 7 8; do
      ( mariadb -uroot -p"$PW" -N -B -e "CALL fmtest.fm_writer('$t',500)" >/dev/null 2>&1 ) &
    done
    if [ "$R" -gt 0 ]; then
      for j in $(seq 1 "$R"); do
        ( mariadb -uroot -p"$PW" -N -B -e "CALL fmtest.fm_reader('$t',500)" >/dev/null 2>&1 ) &
      done
    fi
    wait
    e=$(date +%s)
    echo "D(r=$R) $t  $(($e-$s))s"; check "$t" "${BASE[$t]}" 4000
    BASE[$t]=$(M -e "SELECT SUM(close) FROM fmtest.$t")
  done
done

echo ""
echo "=============================================================="
echo "BENCH-DONE"
echo "=============================================================="
