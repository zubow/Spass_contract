/*
 *   Contract code of paper "Spass: Spectrum Sensing as a Service via Smart Contracts", S. Bayhan, A. Zubow, and A. Wolisz, IEEE DYSPAN, 2018.
 *   
 *   @author Zubow, 2018
 */
pragma solidity ^0.4.0;
contract SSaaS {

    struct Helper { // relevant parameter to identify a helper
        uint id; // helper address
        uint p_f; // false alarm probability / 1000
        uint p_d; // detection probability / 1000
        uint priceSenseBit; // set by the helper
        uint last_report_seq; // seq. number of reported sensing data 
        bytes data; // sensing data as byte array
        bool toBlock; // whether this helper will be blocked in next round
    }

    address public owner; // of this contract -> the SU
    mapping(address => Helper) shMap;
    address[] shLst;
    mapping (address => uint) public pendingWithdrawals;

    /* Service configuration set by contract owner */
    uint sens_f; // sensing sampling, i.e. readings per second
    uint round_s; // helpers report their sensing once per round
    uint data_b; // size of sensing report in bytes send per round to contract
    uint max_p_f; // per 1000; set by regulator
    uint min_p_d; // per 1000; set by regulator
    uint curr_seq; // the current expected seq

    event Debug0(string msg);
    event Debug1(string msg, uint v);

    /* Create new SSaaS contract, specifies the address of the owner */
    constructor () public {
        owner = msg.sender;
    }

    modifier ownerOnly {
        if (msg.sender != owner) { revert(); } _;
    }

    /* Called by the owner (=SU) of this contract to initialize it */
    function init(uint _sens_f, uint _round_s, uint _cp_f, uint _max_p_f, uint _min_p_d) public ownerOnly returns(bool) {
        if (!check_args(_sens_f, _round_s, _cp_f, _max_p_f, _min_p_d)) {
            emit Debug0("incorrect arguments!");
            return false;
        }
        
        sens_f = _sens_f; 
        round_s = _round_s; 
        max_p_f = _max_p_f; 
        min_p_d = _min_p_d;
        data_b = _round_s * _sens_f / _cp_f / 8 + 1;
        curr_seq = 1;
    }

    /* Add new helper to the contract; called by H (helpers) */
    function registerSensingHelper(address _sHelper, uint _id, uint _priceSenseBit, uint _p_f, uint _p_d) public returns(bool) {
        if (shMap[_sHelper].priceSenseBit != 0) {
            emit Debug0("Helper already registered.");
            return false; // sensingHelper with that address was already registered
        }
        if (rejectHelper(_priceSenseBit, _p_f, _p_d)) {
            emit Debug0("Helper rejected; high price or bad sensing accuracy.");
            return false; // helper rejected due to e.g. high price
        }
        shMap[_sHelper] = Helper({id: _id, p_f: _p_f, p_d: _p_d, 
            priceSenseBit: _priceSenseBit, last_report_seq: 0, data: new bytes(data_b), toBlock: false
        }); 
        shLst.push(_sHelper);
        return true;
    }

    /* Check if sufficient Hs available; called by H */
    function waitForOtherHelpers() public returns(bool) {
        if (sufficientRegisteredHelpers()) { 
            return false; // wait for other helpers
        }
        return true;
    }


    /* Periodically called by helpers (H) to report sensing data */
    function reportSensingData(address _sHelper, uint _id, uint _seq, bytes _data) public returns(bool) {
        if (shMap[_sHelper].priceSenseBit == 0) {
            emit Debug0("Unknown sensing helper; please register first.");
            return false; // sensing data from unknown helper; ignore
        }

        if ( (shMap[_sHelper].last_report_seq + 1) != _seq) {
            emit Debug0("Ignoring outdated sensing data.");
            return false; // ignore outdated sensing data
        }
            
        if (_data.length != data_b) {
            emit Debug0("Report has incorrect size.");
            return false;  // incorrect report size
        }
            
        // copy new data
        for (uint i=0; i<data_b; i++) {
            shMap[_sHelper].data[i] = _data[i]; 
        }

        shMap[_sHelper].last_report_seq = _seq;
        return true;
    }

    /* At end of each round contract owner (SU) makes payments to helpers */
    function clearing(uint _seq) public ownerOnly returns(bool) {
        if (curr_seq != _seq) {
            emit Debug0("Clearing incorrect round (seq. number).");
            return false;
        }
        /* run malicious node detection; mark helpers accordingly */
        markMaliciousNodes(); // mark cheaters
        for (uint i=0; i<shLst.length; i++) {
            if (shMap[shLst[i]].toBlock == true) {
                blockSensingHelper(shLst[i]); // block malicious helpers
            } else { 
                notifyPayment(shLst[i]); // notify honest helpers of payment
            }
        } 
        curr_seq++; /* go to next round */ 
        return true;
    }

    /* Notify H of its credit for amount of sensing. */
    function notifyPayment(address _sHelper) ownerOnly private returns(bool) {
        if (shMap[_sHelper].priceSenseBit == 0 || shMap[_sHelper].toBlock) {
            emit Debug0("Sensing helper blocked; no withdrawal possible.");
            return false;
        }
        
        uint payment = shMap[_sHelper].priceSenseBit * (round_s * sens_f); // pay agreed price
        pendingWithdrawals[_sHelper] += payment;
        emit Debug1("Payment made to helper:", payment);
        return true;
    }

    /* Allows helper (H) to withdraw any outstanding credit */
    function withdraw() public returns(bool) {
        uint amount = pendingWithdrawals[msg.sender];
        if (amount <= 0) {
            emit Debug0("Nothing to withdraw.");
            return false;
        }
        pendingWithdrawals[msg.sender] = 0;
        if (msg.sender.send(amount)) { 
            return true; // TX ok
        } else {
            emit Debug0("Failed to withdraw.");
            pendingWithdrawals[msg.sender] = amount;
            return false;
        }
        return true;
    }

    /* Transfer ether to the contract so that helpers can withdraw funds to receive payment for the sensing they performed. */
    function increaseFunds() public payable {}

    /* block a helper, effectively removing it from the list */
    function blockSensingHelper(address _sensingHelper) ownerOnly private returns(bool) {
        if (shMap[_sensingHelper].priceSenseBit == 0) {
            emit Debug0("Unknown helper.");
            return false;
        }
        
        /* Remove blocked helper from list of helpers */
        delete shMap[_sensingHelper];
        for (uint i=0; i<shLst.length; i++) {
            if (shLst[i] == _sensingHelper) {
                delete shLst[i];
                break;
            }
        }
        return true;
    }

    /* Destroy the contract and return funds to owner */
    function selfDestruct() public ownerOnly {
      selfdestruct(owner);
    }

    /* Change ownership of the contract */
    function changeOwner(address _newOwner) public ownerOnly {
      if (owner != _newOwner) {
        owner = _newOwner;
      }
    }

    ////
    //// Helpers
    ////

    /* Algorithm used to detect malicious users */
    function markMaliciousNodes() private returns(bool) {
        // TBD: just mockup: only helpers without report are classified as malicious
        // check if some helpers need to be blacklisted
        for (uint i=0; i<shLst.length; i++) {
            // check if need to block
            if (shMap[shLst[i]].last_report_seq != curr_seq) {
                // no sensing data was reported in last round; block user
                shMap[shLst[i]].toBlock = true;
            }
            // TBD: run algo from paper for detection
        }
        return true;
    }

    /* Check whether we have enough helpers in order to start the SSaaS */
    function sufficientRegisteredHelpers() private view returns (bool) {
        /* Mockup: do more intelligent stuff here; see paper */
        if (shLst.length == 1) {
            return true; // one helper is enough
        }
        return false;
    }

    /* Do checks */
    function check_args(uint _sens_f, uint _round_s, uint _cp_f, uint _max_p_f, uint _min_p_d) private pure returns(bool) {
        if (_max_p_f == 0 || _min_p_d == 1000 || _sens_f == 0 || _round_s == 0 || _cp_f == 0)
            return false;
        /* Do some more checks */
        return true;
    }    

    /* Check whether the helper meets requirements and offers attractive price */
    function rejectHelper(uint _priceSenseBit, uint _p_f, uint _p_d) private pure returns(bool) {
        // Check that _priceSenseBit and p_f/p_d are positive
        if (_priceSenseBit <= 0 || _p_f <= 0 || _p_d <= 0)
            return true;

        if (_p_f > 100 || _p_d < 900)
            return false; // bad sensors

        /* Mockup : do something real here; look into our paper */
        return false;
    }

}
