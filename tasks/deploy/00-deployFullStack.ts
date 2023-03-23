import { HardhatRuntimeEnvironment } from 'hardhat/types';
import inquirer from 'inquirer';
import { typechain } from 'tapioca-sdk';
import { Multicall3 } from 'tapioca-sdk/dist/typechain/utils/MultiCall';
import { constants } from '../../deploy/utils';
import { buildYieldBox } from '../deployBuilds/00-buildYieldBox';
import { buildPenrose } from '../deployBuilds/01-buildPenrose';
import { buildMasterContracts } from '../deployBuilds/02-buildMasterContracts';
import { buildMarketHelpers } from '../deployBuilds/03-buildMarketHelpers';
import { buildMultiSwapper } from '../deployBuilds/04-buildMultiSwapper';
import { buildUSD0 } from '../deployBuilds/06-buildUSDO';
import { buildStableToUSD0Bidder } from '../deployBuilds/07-buildStableToUSD0Bidder';
import { buildSingularityModules } from '../deployBuilds/08-buildSingularityModules';
import { buildMarketProxy } from '../deployBuilds/09-buildMarketProxy';
import { buildPenroseSetup } from '../setups/01-buildPenroseSetup';
import { buildMasterContractsSetup } from '../setups/02-buildMasterContractsSetup';
import { loadVM } from '../utils';

// hh deployFullStack --network goerli
export const deployFullStack__task = async (
    {},
    hre: HardhatRuntimeEnvironment,
) => {
    const tag = await hre.SDK.hardhatUtils.askForTag(hre, 'local');
    const signer = (await hre.ethers.getSigners())[0];
    const VM = await loadVM(hre, tag);

    const chainInfo = hre.SDK.utils.getChainBy(
        'chainId',
        await hre.getChainId(),
    );
    if (!chainInfo) {
        throw new Error('Chain not found');
    }

    let tapToken = hre.SDK.db
        .loadGlobalDeployment(tag, 'tap-token', chainInfo.chainId)
        .find((e) => e.name === 'TapOFT');

    let weth = hre.SDK.db
        .loadGlobalDeployment(tag, 'tap-token', chainInfo.chainId)
        .find((e) => e.name.startsWith('WETHMock'));

    if (!weth) {
        //try to take it again from local deployment
        weth = hre.SDK.db
            .loadLocalDeployment(tag, chainInfo.chainId)
            .find((e) => e.name.startsWith('WETHMock'));
    }
    if (!tapToken) {
        //try to take it again from local deployment
        tapToken = hre.SDK.db
            .loadLocalDeployment(tag, chainInfo.chainId)
            .find((e) => e.name.startsWith('TapOFT'));
    }

    if (!tapToken || !weth) {
        throw new Error('[-] Token not found');
    }

    // 00 - Deploy YieldBox
    const [ybURI, yieldBox] = await buildYieldBox(hre, weth.address);
    VM.add(ybURI).add(yieldBox);

    // 01 - Penrose
    VM.add(
        await buildPenrose(hre, tapToken.address, weth.address, signer.address),
    );

    // 02 - Master contracts
    const [sgl, bb] = await buildMasterContracts(hre);
    VM.add(sgl).add(bb);

    // 03 - MarketHelper
    VM.add(await buildMarketHelpers(hre));

    // 04 - MultiSwapper
    VM.add(
        await buildMultiSwapper(
            hre,
            constants[chainInfo.chainId].uniV2Factory,
            constants[chainInfo.chainId].uniV2PairHash,
        ),
    );

    // 05 - SingularityModules
    const [liq, lendBorrow] = await buildSingularityModules(hre);
    VM.add(liq).add(lendBorrow);

    // 06 USDO
    VM.add(await buildUSD0(hre, chainInfo.address, signer.address));

    // 07 - CurveSwapper-buildStableToUSD0Bidder
    const [curveSwapper, curveStableToUsd0] = await buildStableToUSD0Bidder(
        hre,
        constants[chainInfo.chainId].crvStablePool,
    );
    VM.add(curveSwapper).add(curveStableToUsd0);

    // 08 - MarketsProxy
    const marketProxy = await buildMarketProxy(
        hre,
        chainInfo.address,
        signer.address,
    );
    VM.add(marketProxy);

    // Add and execute
    await VM.execute(3, false);
    VM.save();
    const { wantToVerify } = await inquirer.prompt({
        type: 'confirm',
        name: 'wantToVerify',
        message: 'Do you want to verify the contracts?',
    });
    if (wantToVerify) {
        await VM.verify();
    }

    // After deployment setup
    const vmList = VM.list();
    const multiCall = typechain.Multicall.Multicall3__factory.connect(
        hre.SDK.config.MULTICALL_ADDRESS,
        signer,
    );
    const calls: Multicall3.Call3Struct[] = [
        ...(await buildPenroseSetup(hre, vmList, signer.address)),
        ...(await buildMasterContractsSetup(hre, vmList)),
    ];

    // Execute
    console.log('[+] After deployment setup calls number: ', calls.length);
    if (calls.length > 0) {
        try {
            const tx = await (await multiCall.aggregate3(calls)).wait(1);
            console.log(
                '[+] After deployment setup multicall Tx: ',
                tx.transactionHash,
            );
        } catch (e) {
            // If one fail, try them one by one
            for (const call of calls) {
                await (
                    await signer.sendTransaction({
                        data: call.callData,
                        to: call.target,
                    })
                ).wait();
            }
        }
    }

    console.log('[+] Stack deployed! 🎉');
};
