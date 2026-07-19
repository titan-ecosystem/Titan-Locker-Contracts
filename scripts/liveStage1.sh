#!/bin/bash
# Live verification stage 1: configure fee, create an ERC20 lock (ETH-fee path)
# and a vesting lock (token-fee path), read back state. Logs tx hashes.
cd "$(dirname "$0")/.."
RPC=$(grep '^ROBINHOOD_RPC_URL=' .env | cut -d= -f2 | tr -d '"[:space:]')
KEY=$(grep '^DEPLOYER_PRIVATE_KEY=' .env | cut -d= -f2 | tr -d '"[:space:]')
M=0x26b0654a0756dcd036d4e7215324f3d2be34d79e
TOK=0xadd0fa2f5ae8c9091ad76ec164667a1763600688
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
LOG=/tmp/lc1.log; : > "$LOG"

send() { cast send --rpc-url "$RPC" --private-key "$KEY" --legacy --gas-price 200000000 --json "$@" 2>&1 | grep '^{'; }
p() { python3 -c "import sys,json; d=json.load(sys.stdin); print('$1: status='+d['status']+' tx='+d['transactionHash'])"; }

echo "== setEthFee -> 0.00001 ETH (owner config) ==" | tee -a "$LOG"
send --gas-limit 120000 "$M" "setEthFee(uint256)" 10000000000000 | p setEthFee | tee -a "$LOG"

echo "== approve manager to spend TTV2 ==" | tee -a "$LOG"
send --gas-limit 120000 "$TOK" "approve(address,uint256)" "$M" "$MAX" | p approve | tee -a "$LOG"

TS=$(cast block latest --rpc-url "$RPC" --field timestamp)
WIN=$((TS+300))
echo "chainTime=$TS  unlock/vestEnd=$WIN (300s window)" | tee -a "$LOG"
echo "$TS" > /tmp/ts

echo "== createTokenLock (ETH-fee path, locks 100% of 1000 TTV2) ==" | tee -a "$LOG"
# maxTokenFeeBps_ is ignored on the ETH-fee path (only checked when paying the
# fee in-kind), so 10000 here just means "accept anything" - it's a no-op.
send --gas-limit 6000000 --value 10000000000000 "$M" "createTokenLock(address,uint256,uint40,uint16)" "$TOK" 1000000000000000000000 "$WIN" 10000 | p createTokenLock | tee -a "$LOG"

echo "== createVestingLock (token-fee path 5%, grants 950 TTV2, linear over 300s) ==" | tee -a "$LOG"
# 500 = the caller's max acceptable fee (5%); reverts instead of silently
# paying more if the live rate was bumped before this mines.
send --gas-limit 6000000 "$M" "createVestingLock(address,uint256,uint40,uint40,uint40,uint16)" "$TOK" 1000000000000000000000 "$TS" "$TS" "$WIN" 500 | p createVestingLock | tee -a "$LOG"

LOCK0=$(cast call --rpc-url "$RPC" "$M" "getTokenLockAddress(uint40)(address)" 0)
LOCK1=$(cast call --rpc-url "$RPC" "$M" "getTokenLockAddress(uint40)(address)" 1)
echo "$LOCK0" > /tmp/lock0; echo "$LOCK1" > /tmp/lock1
echo "erc20 lock (id0):  $LOCK0" | tee -a "$LOG"
echo "vesting lock (id1): $LOCK1" | tee -a "$LOG"
echo "-- erc20 lock balance:  $(cast call --rpc-url "$RPC" "$LOCK0" "getLockData()(uint8,uint40,address,address,address,uint256,address,uint40,uint40,uint256)" | tail -1)" | tee -a "$LOG"
echo "-- vesting grant total: $(cast call --rpc-url "$RPC" "$LOCK1" "getVesting()(uint40,uint40,uint40,uint256,uint256)" | sed -n 4p)" | tee -a "$LOG"
echo "CYCLE1 DONE" | tee -a "$LOG"
