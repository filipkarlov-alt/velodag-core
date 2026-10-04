#!/usr/bin/env bash
#
# VeloDAG node deployment script.
# Automates the mechanical parts of launch. Does NOT automate treasury
# address generation into the source code -- that step requires editing
# vdag-consensus/src/lib.rs with the real address, which this script will
# print instructions for but not do blindly, since a mistake there affects
# every dev-tax reward the network ever earns.
#
# Usage:
#   ./deploy_velodag_node.sh
#
# Run from the repo root. Safe to re-run -- idempotent where practical
# (won't recreate an existing wallet, won't fail if the systemd user
# already exists).

set -euo pipefail

REPO_ROOT="$(pwd)"
DEPLOY_USER="velodag"
DEPLOY_DIR="/home/${DEPLOY_USER}/velodag"
SERVICE_NAME="velodag"

echo "=== 1. Build ==="
if ! command -v cargo &>/dev/null; then
    echo "cargo not found. Install Rust first: https://rustup.rs"
    exit 1
fi
cargo build --release

echo "=== 2. Run tests before deploying anything ==="
cargo test --workspace
echo "Tests passed."

echo "=== 3. Treasury wallet ==="
if [ -f "treasury_wallet.json" ]; then
    echo "treasury_wallet.json already exists -- skipping creation."
    echo "If this is a fresh deployment and you don't recognize this file, STOP and investigate before continuing."
else
    echo "No treasury wallet found."
    read -rp "Create one now? [y/N] " create_wallet
    if [[ "$create_wallet" =~ ^[Yy]$ ]]; then
        read -rsp "Enter a strong wallet password: " wallet_password
        echo
        export VDAG_WALLET_PASSWORD="$wallet_password"
        ./target/release/vdag-node wallet create treasury_wallet.json
        echo
        echo "Treasury address:"
        ./target/release/vdag-node wallet address treasury_wallet.json
        echo
        echo "*** IMPORTANT ***"
        echo "1. Back up treasury_wallet.json AND your password, separately, right now."
        echo "2. The address printed above still needs to be manually put into"
        echo "   DEV_TREASURY_ADDRESS in vdag-consensus/src/lib.rs, replacing the"
        echo "   placeholder [0xdd; 32], and the project rebuilt -- this script"
        echo "   does not do that automatically. See VeloDAG_Launch_Guide.md section 2."
        echo "*****************"
        read -rp "Press Enter once you've backed up the wallet and understand the next step..."
    else
        echo "Skipping wallet creation. Note: DEV_TREASURY_ADDRESS is currently a placeholder"
        echo "([0xdd; 32]) until you generate and wire in a real one."
    fi
fi

echo "=== 4. Network configuration ==="
read -rp "Network [devnet/testnet/mainnet] (default devnet): " network
network="${network:-devnet}"

read -rp "Fixed P2P port (default 40000): " p2p_port
p2p_port="${p2p_port:-40000}"

read -rp "Bind RPC to a non-loopback address? [y/N]: " expose_rpc
rpc_addr="127.0.0.1:8545"
rpc_token_line=""
if [[ "$expose_rpc" =~ ^[Yy]$ ]]; then
    read -rp "RPC bind address (e.g. 0.0.0.0:8545): " rpc_addr
    read -rsp "RPC auth token (required if exposing RPC): " rpc_token
    echo
    rpc_token_line="Environment=\"VDAG_RPC_TOKEN=${rpc_token}\""
fi

echo "=== 5. System user + directory ==="
if ! id "$DEPLOY_USER" &>/dev/null; then
    sudo useradd -r -s /bin/false "$DEPLOY_USER"
    echo "Created user $DEPLOY_USER"
else
    echo "User $DEPLOY_USER already exists"
fi

sudo mkdir -p "$DEPLOY_DIR"
sudo cp "$REPO_ROOT/target/release/vdag-node" "$DEPLOY_DIR/"
[ -f "$REPO_ROOT/treasury_wallet.json" ] && sudo cp "$REPO_ROOT/treasury_wallet.json" "$DEPLOY_DIR/"
for f in "$REPO_ROOT"/bootstrap.*.json; do
    [ -f "$f" ] && sudo cp "$f" "$DEPLOY_DIR/"
done
sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"

echo "=== 6. systemd unit ==="
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=VeloDAG Node
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${DEPLOY_DIR}
Environment="VDAG_NETWORK=${network}"
Environment="VDAG_P2P_PORT=${p2p_port}"
Environment="VDAG_RPC_ADDR=${rpc_addr}"
${rpc_token_line}
ExecStart=${DEPLOY_DIR}/vdag-node
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"

echo
echo "=== 7. Firewall reminder (not automated -- provider-specific) ==="
echo "Open TCP port ${p2p_port} for P2P in your cloud provider's firewall/security group."
if [[ "$expose_rpc" =~ ^[Yy]$ ]]; then
    echo "Also open the RPC port from ${rpc_addr} -- you've set a token, so this is intentional."
else
    echo "RPC is loopback-only -- no firewall rule needed for it."
fi

echo
echo "=== 8. Verify ==="
echo "Run: sudo systemctl status ${SERVICE_NAME}"
echo "Run: journalctl -u ${SERVICE_NAME} -f"
echo "Look for: 'Local P2P Node Peer ID', 'Local node listening', and '[⏱️ Block Mined Locally]' roughly every second."
echo
echo "Done."
