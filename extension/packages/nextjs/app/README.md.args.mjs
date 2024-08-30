export const extraContents = `## 🚀 Setup ERC-4626 Vault Extension

This extension introduces an ERC-4626 vault contract and demonstrates how to interact with it, including deposit/redeem tokens.

The ERC-20 token contract is implemented using the [ERC-20 token implementation](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol) from OpenZeppelin.

The ERC-4626 token contract is implemented using the [ERC-4626 token implementation](https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC4626.sol) from solmate.

### Setup

Deploy your contract running \`\`\`yarn deploy\`\`\`

### Interact with the token

Start the front-end with \`\`\`yarn start\`\`\` and go to the _/vault_ page to interact with your deployed ERC-4626 token.

You can check the code at \`\`\`packages/nextjs/app/vault/page.tsx\`\`\`.

`;