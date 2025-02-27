use starknet::ContractAddress;

#[starknet::interface]
trait IStake<TContractState> {
    fn stake(ref self: TContractState, amount: u256) -> bool;
    fn withdraw(ref self: TContractState, amount: u256) -> bool;
    fn get_stake_balance(self: @TContractState) -> u256;
    fn get_bwc_token_address(self: @TContractState) -> ContractAddress;
    fn get_reward_token_address(self: @TContractState) -> ContractAddress;
    fn get_receipt_token_address(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
mod BWCStakingContract {
    /////////////////////////////
    //LIBRARY IMPORTS
    /////////////////////////////        
    use core::serde::Serde;
    use core::integer::u64;
    use core::zeroable::Zeroable;
    use basic_staking_dapp::bwc_staking_contract::IStake;
    use basic_staking_dapp::erc20_token::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};

    /////////////////////
    //STAKING DETAIL
    /////////////////////
    // #[derive(Drop)]
    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct StakeDetail {
        time_staked: u64,
        amount: u256,
        status: bool,
    }

    ////////////////////
    //STORAGE
    ////////////////////
    #[storage]
    struct Storage {
        staker: LegacyMap::<ContractAddress, StakeDetail>,
        bwcerc20_token_address: ContractAddress,
        receipt_token_address: ContractAddress,
        reward_token_address: ContractAddress,
    }

    //////////////////
    // CONSTANTS
    //////////////////
    const MIN_TIME_BEFORE_WITHDRAW: u64 =
        240_u64; // Minimun time (in seconds) staked token can be withdrawn from pool. Equivalent to 4 minutes (TODO: Change to 1 hour)

    /////////////////
    //EVENTS
    /////////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TokenStaked: TokenStaked,
        TokenWithdraw: TokenWithdraw
    }

    #[derive(Drop, starknet::Event)]
    struct TokenStaked {
        staker: ContractAddress,
        amount: u256,
        time: u64
    }

    #[derive(Drop, starknet::Event)]
    struct TokenWithdraw {
        staker: ContractAddress,
        amount: u256,
        time: u64
    }

    /////////////////
    //CUSTOM ERRORS
    /////////////////
    mod Errors {
        const INSUFFICIENT_FUND: felt252 = 'STAKE: Insufficient fund';
        const INVALID_WITHDRAW_TIME: felt252 = 'Not yet time to withdraw';
        const INSUFFICIENT_BALANCE: felt252 = 'STAKE: Insufficient balance';
        const ADDRESS_ZERO: felt252 = 'Address zero not allowed';
        const NOT_TOKEN_ADDRESS: felt252 = 'STAKE: Not a token address';
        const ZERO_AMOUNT: felt252 = 'Zero amount';
        const INSUFFICIENT_FUNDS: felt252 = 'STAKE: Insufficient funds';
        const LOW_CBWCRT_BALANCE: felt252 = 'STAKE: Low receipt_tkn_balance';
        const NOT_WITHDRAW_TIME: felt252 = 'STAKE: Not yet withdraw time';
        const LOW_CONTRACT_BALANCE: felt252 = 'STAKE: Low contract balance';
        const AMOUNT_NOT_ALLOWED: felt252 = 'STAKE: Amount not allowed';
        const WITHDRAW_AMOUNT_NOT_ALLOWED: felt252 = 'Withdraw amount not allowed';
        const NOT_WITHDRAWAL_TIME: felt252 = 'Not yet time to withdraw';
        const LOW_REWARD_TKN: felt252 = 'low reward tkn to send';
        const LOW_BWC_TKN: felt252 = 'Not enough BWC token to send';
        const LOW_RECEIPT_TKN_ALLOW: felt252 = 'low receipt tkn allowance';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        bwcerc20_token_address: ContractAddress,
        receipt_token_address: ContractAddress,
        reward_token_address: ContractAddress,
    ) {
        self.bwcerc20_token_address.write(bwcerc20_token_address);
        self.reward_token_address.write(reward_token_address);
        self.receipt_token_address.write(receipt_token_address);
    }

    #[abi(embed_v0)]
    impl IStakeImpl of super::IStake<ContractState> {
        // Function allows caller to stake their token
        // @amount: Amount of token to stake
        // @BWCERC20TokenAddr: Contract address of token to stake
        // @receipt_token: Contract address of receipt token
        fn stake(ref self: ContractState, amount: u256) -> bool {
            // CHECK -> EFFECTS -> INTERACTION

            let caller: ContractAddress = get_caller_address(); // Caller address
            let address_this: ContractAddress = get_contract_address(); // Address of this contract
            let bwc_erc20_contract = IERC20Dispatcher {
                contract_address: self.bwcerc20_token_address.read()
            };
            let receipt_contract = IERC20Dispatcher {
                contract_address: self.receipt_token_address.read()
            };

            assert(!caller.is_zero(), Errors::ADDRESS_ZERO); // Caller cannot be address 0
            assert(amount > 0, Errors::ZERO_AMOUNT); // Cannot stake zero amount
            assert(
                amount <= bwc_erc20_contract.balance_of(caller), Errors::INSUFFICIENT_FUNDS
            ); // Caller cannot stake more than token balance

            assert(
                receipt_contract.balance_of(address_this) >= amount, Errors::LOW_CBWCRT_BALANCE
            ); // Contract must have enough receipt token to transfer out

            // STEP 1: Staker must first allow this contract to spend `amount` of Stake Tokens from staker's account

            assert(
                bwc_erc20_contract.allowance(caller, address_this) >= amount,
                Errors::AMOUNT_NOT_ALLOWED
            ); // This contract should be allowed to spend `amount` stake tokens from staker account

            // set storage variable
            let prev_stake: StakeDetail = self.staker.read(caller);

            let new_stake: StakeDetail = StakeDetail {
                time_staked: get_block_timestamp(), amount: prev_stake.amount + amount, status: true
            };

            self.staker.write(caller, new_stake);

            // STEP 2
            // transfer stake token from caller to this contract
            bwc_erc20_contract.transfer_from(caller, address_this, amount);

            // STEP 3
            // transfer receipt token from this contract to staker account
            receipt_contract.transfer(caller, amount);

            // STEP 4
            //
            // Staker calls the approve function of receipt token contract and approves this contract to transfer out `amount` receipt from staker account
            // Reason for this is to allow this contract withdraw the receipt token before sending back stake tokens
            //  receipt_contract.approve(address_this, amount);

            self
                .emit(
                    Event::TokenStaked(
                        TokenStaked { staker: caller, amount, time: get_block_timestamp() }
                    )
                );
            true
        }

        fn get_stake_balance(self: @ContractState) -> u256 {
            self.staker.read(get_caller_address()).amount
        }


        // Function allows caller to withdraw their staked token and get rewarded
        // @amount: Amount of token to withdraw
        // @BWCERC20TokenAddr: Contract address of token to withdraw
        fn withdraw(ref self: ContractState, amount: u256) -> bool {
            // get address of caller
            let caller = get_caller_address();
            let address_this: ContractAddress = get_contract_address(); // Address of this contract
            let bwc_erc20_contract = IERC20Dispatcher {
                contract_address: self.bwcerc20_token_address.read()
            };
            let receipt_contract = IERC20Dispatcher {
                contract_address: self.receipt_token_address.read()
            };
            let reward_contract = IERC20Dispatcher {
                contract_address: self.reward_token_address.read()
            };

            // get stake details
            let mut stake: StakeDetail = self.staker.read(caller);
            // get amount caller has staked
            let stake_amount = stake.amount;
            // get last timestamp caller staked
            let stake_time = stake.time_staked;

            assert(!caller.is_zero(), Errors::ADDRESS_ZERO); // Caller cannot be address 0
            assert(amount > 0, Errors::ZERO_AMOUNT);
            assert(
                amount <= stake_amount, Errors::WITHDRAW_AMOUNT_NOT_ALLOWED
            ); // Staker cannot withdraw more than staked amount
            assert(self.is_time_to_withdraw(stake_time), Errors::INVALID_WITHDRAW_TIME);
            assert(
                reward_contract.balance_of(address_this) >= amount, Errors::LOW_REWARD_TKN
            ); // This contract must have enough reward token to transfer to Staker
            assert(
                bwc_erc20_contract.balance_of(address_this) >= amount, Errors::LOW_BWC_TKN
            ); // This contract must have enough stake token to transfer back to Staker
            assert(
                receipt_contract.allowance(caller, address_this) >= amount,
                Errors::LOW_RECEIPT_TKN_ALLOW
            ); // Staker has approved this contract to withdraw receipt token from Staker's account

            // Update stake detail
            self
                .staker
                .write(
                    caller,
                    StakeDetail {
                        amount: stake_amount - amount, time_staked: stake_time, status: stake.status
                    }
                );

            // Withdraw receipt token from staker account
            receipt_contract.transfer_from(caller, address_this, amount);

            // Send Reward token to staker account
            reward_contract.transfer(caller, amount);

            // Send back stake token to caller account
            bwc_erc20_contract.transfer(caller, amount);

            self
                .emit(
                    Event::TokenWithdraw(TokenWithdraw { staker: caller, amount, time: stake_time })
                );
            true
        }

        fn get_bwc_token_address(self: @ContractState) -> ContractAddress {
            self.bwcerc20_token_address.read()
        }

        fn get_reward_token_address(self: @ContractState) -> ContractAddress {
            self.reward_token_address.read()
        }


        fn get_receipt_token_address(self: @ContractState) -> ContractAddress {
            self.receipt_token_address.read()
        }
    }


    #[generate_trait]
    impl Utility of UtilityTrait {
        // fn calculate_reward(self: ContractState, account: ContractAddress) -> u256 {
        //     let caller = get_caller_address();
        //     let stake_status: bool = self.staker.read(caller).status;
        //     let stake_amount = self.staker.read(caller).amount;
        //     let stake_time: u64 = self.staker.read(caller).time_staked;
        //     if stake_status == false {
        //         return 0;
        //     }
        //     let reward_per_month = (stake_amount * 10);
        //     let time = get_block_timestamp() - stake_time;
        //     let reward = (reward_per_month * time.into() * 1000) / MIN_STAKE_TIME.into();
        //     return reward;
        // }

        fn is_time_to_withdraw(self: @ContractState, stake_time: u64) -> bool {
            let caller = get_caller_address();
            let now = get_block_timestamp();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_time: u64 = stake.time_staked;
            let withdraw_time = stake_time + MIN_TIME_BEFORE_WITHDRAW;

            if (now >= withdraw_time) {
                true
            } else {
                false
            }
        }

        //getting the next withdrawal time
        fn get_next_withdraw_time(self: @ContractState) -> u64 {
            let caller = get_caller_address();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_time = stake.time_staked;
            let next_withdrawal_time = stake_time + MIN_TIME_BEFORE_WITHDRAW;

            next_withdrawal_time
        }

        //getting the next stake time:
        fn get_next_stake_time(self: @ContractState) -> u64 {
            let caller = get_caller_address();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_time = stake.time_staked;
            let next_stake_time: u64 = stake_time + MIN_TIME_BEFORE_WITHDRAW;

            next_stake_time
        }

        //checking if the user has staked before:
        fn check_if_user_staked(self: @ContractState) -> bool {
            let caller = get_caller_address();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_status: bool = stake.status;

            stake_status
        }

        //getting the amount a user staked:
        fn get_stake_amount(self: @ContractState, amount: u256) -> u256 {
            let caller = get_caller_address();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_amount = stake.amount;

            stake_amount
        }

        //checking the last time a user staked:
        fn last_stake_time(self: @ContractState, stake_time: u64) -> u64 {
            let caller = get_contract_address();
            let stake: StakeDetail = self.staker.read(caller);
            let stake_time = stake.time_staked;

            stake_time
        }
    }
}
// TODO: 
// 1. Make error messages more descriptive
// 2. Add a util function to check if user has staked at any point in time
// 3. Add a util function to check amount a user staked
// 4. Convert non-custom errors to custom errors
// 5. Add util function to check the last time a user staked


