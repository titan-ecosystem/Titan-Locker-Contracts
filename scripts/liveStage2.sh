#!/bin/bash
# Live verification stage 2: partial vesting release at midpoint, then full
# release at end + withdraw the matured ERC20 lock. Logs tx hashes + amounts.
cd "$(dirname "$0")/.."
RPC=$(grep '^ROBINHOOD_RPC_URL=' .env | cut -d= -f2 | tr -d '"[:space:]')
KEY=$(grep '^DEPLOYER_PRIVATE_KEY=' .env | cut -d= -f2 | tr -d '"[:space:]')
TOK=0xadd0fa2f5ae8c9091ad76ec164667a1763600688
DEP=0x5C773302FBEED11fA59a6939f0354678738B02DB
TS=$(cat /tmp/ts); END=$((TS+300)); MID=$((TS+150))
LOCK0=$(cat /tmp/lock0); LOCK1=$(cat /tmp/lock1)
LOG=/tmp/lc2.log; : > "$LOG"

send() { cast send --rpc-url "$RPC" --private-key "$KEY" --legacy --gas-price 200000000 --json "$@" 2>&1 | grep '^{'; }
p() { python3 -c "import sys,json; d=json.load(sys.stdin); print('$1: status='+d['status']+' tx='+d['transactionHash'])"; }
rel() { cast call --rpc-url "$RPC" "$LOCK1" "releasedAmount()(uint256)"; }
wait_until() { while true; do n=$(cast block latest --rpc-url "$RPC" --field timestamp); echo "  chainTime=$n (target $1)"; [ "$n" -ge "$1" ] && break; sleep 8; done; }

echo "== waiting for vesting midpoint (~50%) ==" | tee -a "$LOG"
wait_until "$MID"
echo "releasable now: $(cast call --rpc-url "$RPC" "$LOCK1" "releasable()(uint256)")" | tee -a "$LOG"
echo "== release() partial ==" | tee -a "$LOG"
send --gas-limit 300000 "$LOCK1" "release()" | p release_partial | tee -a "$LOG"
echo "cumulative released after partial: $(rel)" | tee -a "$LOG"

echo "== waiting for vesting end + unlock ==" | tee -a "$LOG"
wait_until "$((END+5))"
echo "== release() remainder (full) ==" | tee -a "$LOG"
send --gas-limit 300000 "$LOCK1" "release()" | p release_full | tee -a "$LOG"
echo "cumulative released after full: $(rel)  (grant was 950e18)" | tee -a "$LOG"

echo "== withdraw() matured ERC20 lock ==" | tee -a "$LOG"
send --gas-limit 300000 "$LOCK0" "withdraw()" | p withdraw_erc20 | tee -a "$LOG"
echo "erc20 lock balance after withdraw: $(cast call --rpc-url "$RPC" "$LOCK0" "getLockData()(uint8,uint40,address,address,address,uint256,address,uint40,uint40,uint256)" | tail -1)" | tee -a "$LOG"
echo "CYCLE2 DONE" | tee -a "$LOG"
