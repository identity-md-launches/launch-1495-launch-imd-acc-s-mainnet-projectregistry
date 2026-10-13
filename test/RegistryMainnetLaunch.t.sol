// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";

/// @dev Local factory rehearsal; never broadcasts a transaction.
contract RegistryLaunchFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "registry deployment failed");
    }
}

contract RegistryMainnetLaunchTest is Test {
    function test_manifestDeploysOnlyRegistryOnEmptyMainnet() public {
        vm.chainId(1);
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "ProjectRegistry");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "do not redeploy the Stacker");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 7);

        address intake = vm.parseAddress(args[0]);
        address imd = vm.parseAddress(args[1]);
        address stacker = vm.parseAddress(args[2]);
        address signer = vm.parseAddress(args[3]);
        assertEq(intake, 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(imd, 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(stacker, 0x06909F672301F28A810f78cfe7a754851269F4F0);
        assertEq(signer, 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(vm.parseUint(args[4]), 1);
        assertEq(vm.parseUint(args[5]), 20e18);
        assertEq(vm.parseUint(args[6]), 7 days);
        assertEq(intake.code.length, 0);
        assertEq(imd.code.length, 0);
        assertEq(stacker.code.length, 0);
        assertEq(signer.code.length, 0);

        bytes memory initCode = abi.encodePacked(
            type(ProjectRegistry).creationCode,
            abi.encode(
                intake,
                imd,
                stacker,
                signer,
                vm.parseUint(args[4]),
                vm.parseUint(args[5]),
                uint64(vm.parseUint(args[6]))
            )
        );
        assertLe(initCode.length, 49_152, "EIP-3860 init code limit");
        RegistryLaunchFactory factory = new RegistryLaunchFactory();
        bytes32 salt = keccak256("mainnet registry rehearsal");
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), address(factory));
        address deployed = factory.deploy(initCode, salt);
        assertEq(deployed, expected);
        assertEq(vm.getNonce(address(factory)), 2, "exactly one application created");
        assertEq(vm.getNonce(deployed), 1, "constructor creates no other contracts");
        ProjectRegistry registry = ProjectRegistry(deployed);
        assertEq(address(registry.intake()), intake);
        assertEq(address(registry.oracleAsset()), imd);
        assertEq(registry.stacker(), stacker);
        assertEq(registry.oracleSigner(), signer);
        assertEq(registry.questionChainId(), 1);
        assertEq(registry.challengeBond(), 20e18);
        assertEq(registry.challengeCooldown(), 7 days);
        (bool ownerCall,) = deployed.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerCall, "the factory gains no ownership");

        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170 runtime limit");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
