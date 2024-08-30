"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { formatEther, parseEther } from "viem";
import { useAccount } from "wagmi";
import { InputBase } from "~~/components/scaffold-eth";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const Vault: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  const [depositAmount, setDepositAmount] = useState<string>("");
  const [redeemAmount, setRedeemAmount] = useState<string>("");

  const { data: vaultBalance } = useScaffoldReadContract({
    contractName: "Vault",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { writeContractAsync: writeVaultAsync } = useScaffoldWriteContract("Vault");

  const vaultAddress = useDeployedContractInfo("Vault").data?.address;

  const { data: balance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: allowance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "allowance",
    args: [connectedAddress, vaultAddress],
  });

  const { writeContractAsync: writeSE2TokenAsync } = useScaffoldWriteContract("MockUSDC");

  return (
    <div className="min-h-screen bg-gradient-to-b from-gray-900 to-gray-800 text-white">
      <div className="max-w-4xl mx-auto px-4 py-16">
        <h1 className="text-5xl font-bold mb-8">DeFi Vault</h1>

        <div className="bg-gray-800 rounded-lg p-6 mb-8">
          <h2 className="text-2xl font-semibold mb-4">About</h2>
          <p className="text-gray-300 mb-4">
            This extension introduces an ERC-4626 vault contract and demonstrates how to interact with it, including
            deposit/redeem tokens.
          </p>
          <p className="text-gray-300">
            The ERC-4626 token contract is implemented using the{" "}
            <a
              href="https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC4626.sol"
              className="text-blue-400 hover:text-blue-300 transition-colors"
              target="_blank"
              rel="noopener noreferrer"
            >
              ERC-4626 token implementation
            </a>{" "}
            from solmate.
          </p>
        </div>

        <div className="bg-gray-800 rounded-lg p-6 mb-8">
          <h2 className="text-2xl font-semibold mb-4">Your Balances</h2>
          <div className="flex justify-between items-center mb-4">
            <span className="text-gray-300">MockUSDC Balance:</span>
            <span className="text-xl font-medium">{balance ? formatEther(balance) : 0} tokens</span>
          </div>
          <div className="flex justify-between items-center mb-4">
            <span className="text-gray-300">Approved MockUSDC:</span>
            <span className="text-xl font-medium">{allowance ? formatEther(allowance) : 0} tokens</span>
          </div>
          <div className="flex space-x-4">
            <button
              className="flex-1 bg-blue-500 hover:bg-blue-600 text-white font-bold py-2 px-4 rounded transition-colors"
              onClick={async () => {
                await writeSE2TokenAsync({ functionName: "mint", args: [connectedAddress, parseEther("100")] });
              }}
            >
              Mint 100 Tokens
            </button>
            <button
              className="flex-1 bg-green-500 hover:bg-green-600 text-white font-bold py-2 px-4 rounded transition-colors"
              onClick={async () => {
                await writeSE2TokenAsync({ functionName: "approve", args: [vaultAddress, parseEther("100")] });
              }}
            >
              Approve Tokens
            </button>
          </div>
        </div>

        <div className="bg-gray-800 rounded-lg p-6">
          <h2 className="text-2xl font-semibold mb-6">Vault Operations</h2>

          <div className="mb-8">
            <h3 className="text-xl font-medium mb-4">Deposit</h3>
            <div className="flex items-center space-x-4 mb-4">
              <InputBase value={depositAmount} onChange={setDepositAmount} placeholder="0" />
              <button
                disabled={!balance}
                className="bg-gray-600 hover:bg-gray-500 text-white font-bold py-2 px-4 rounded transition-colors"
                onClick={() => {
                  if (balance) {
                    setDepositAmount(formatEther(balance));
                  }
                }}
              >
                Max
              </button>
            </div>
            <button
              className="w-full bg-blue-500 hover:bg-blue-600 text-white font-bold py-2 px-4 rounded transition-colors"
              disabled={!depositAmount}
              onClick={async () => {
                await writeVaultAsync({
                  functionName: "deposit",
                  args: [parseEther(depositAmount), connectedAddress],
                });
                setDepositAmount("");
              }}
            >
              Deposit
            </button>
          </div>

          <div>
            <h3 className="text-xl font-medium mb-4">Redeem</h3>
            <div className="flex justify-between items-center mb-4">
              <span className="text-gray-300">Your Vault Balance:</span>
              <span className="text-xl font-medium">
                {vaultBalance ? Number(formatEther(vaultBalance)).toFixed(2) : "0.00"} vault tokens
              </span>
            </div>
            <div className="flex items-center space-x-4 mb-4">
              <InputBase value={redeemAmount} onChange={setRedeemAmount} placeholder="0" />
              <button
                disabled={!vaultBalance}
                className="bg-gray-600 hover:bg-gray-500 text-white font-bold py-2 px-4 rounded transition-colors"
                onClick={() => {
                  if (vaultBalance) {
                    setRedeemAmount(formatEther(vaultBalance));
                  }
                }}
              >
                Max
              </button>
            </div>
            <button
              className="w-full bg-green-500 hover:bg-green-600 text-white font-bold py-2 px-4 rounded transition-colors"
              disabled={!redeemAmount}
              onClick={async () => {
                await writeVaultAsync({
                  functionName: "redeem",
                  args: [parseEther(redeemAmount), connectedAddress, connectedAddress],
                });
                setRedeemAmount("");
              }}
            >
              Redeem
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Vault;
