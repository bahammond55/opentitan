// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// smoke test vseq
class kmac_smoke_vseq extends kmac_base_vseq;

  `uvm_object_utils(kmac_smoke_vseq)
  `uvm_object_new

  // TODO: 200 is chosen as upper bound due to large configuration space for KMAC.
  //       If this large range causes noticeable simulation slowdown, reduce it.
  constraint num_trans_c {
    num_trans inside {[1:200]};
  }

  // If in KMAC mode, the function name has to be "KMAC" string
  constraint legal_fname_c {
    if (kmac_en) {
      fname_len == 4;
      fname_arr[0] == 75; // "K"
      fname_arr[1] == 77; // "M"
      fname_arr[2] == 65; // "A"
      fname_arr[3] == 67; // "C"
    } else {
      fname_len == 0;
    }
  }

  constraint custom_str_len_c {
    custom_str_len == 0;
  }

  constraint en_sideload_c {
    en_sideload == 0;
  }

  constraint entropy_mode_c {
    entropy_mode == EntropyModeSw;
  }

  constraint entropy_fast_process_c {
    entropy_fast_process == 0;
  }

  constraint entropy_ready_c {
    entropy_ready == 1;
  }

  constraint err_processed_c {
    err_processed == 0;
  }

  // Constraint output byte length to be at most the keccak block size (168/136).
  // This way we can read the entire digest without having to manually squeeze data.
  constraint output_len_c {
    output_len inside {[1:keccak_block_size]};
  }

  // for smoke test keep message below 32 bytes
  constraint msg_c {
    msg.size() dist {
      0      :/ 1,
      [1:32] :/ 9
    };
  }

  // We want to disable do_kmac_init here because we wil re-initialize the KMAC each time we do
  // a message hash.
  virtual task pre_start();
    do_kmac_init = 0;
    super.pre_start();
  endtask

  // Do a full message hash, repeated num_trans times
  task body();

    logic [keymgr_pkg::KeyWidth-1:0] sideload_share0;
    logic [keymgr_pkg::KeyWidth-1:0] sideload_share1;

    `uvm_info(`gfn, $sformatf("Starting %0d message hashes", num_trans), UVM_LOW)
    for (int i = 0; i < num_trans; i++) begin
      `uvm_info(`gfn, $sformatf("iteration: %0d", i), UVM_HIGH)

      `DV_CHECK_RANDOMIZE_FATAL(this)

      kmac_init();
      `uvm_info(`gfn, "kmac_init done", UVM_HIGH)

      set_prefix();

      if (kmac_en) begin
        // provide a random sideloaded key
        if (en_sideload || provide_sideload_key) begin
          `DV_CHECK_STD_RANDOMIZE_FATAL(sideload_share0)
          `DV_CHECK_STD_RANDOMIZE_FATAL(sideload_share1)

          `uvm_info(`gfn, $sformatf("sideload_key_share0: 0x%0x", sideload_share0), UVM_HIGH)
          `uvm_info(`gfn, $sformatf("sideload_key_share1: 0x%0x", sideload_share1), UVM_HIGH)

          cfg.sideload_vif.drive_sideload_key(1, sideload_share0, sideload_share1);
        end
        // write the SW key to the CSRs
        write_key_shares();
      end

      if (cfg.enable_masking && entropy_mode == EntropyModeSw) begin
        provide_sw_entropy();
      end

      // issue Start cmd
      issue_cmd(CmdStart);

      // write the message into msgfifo
      `uvm_info(`gfn, $sformatf("msg: %0p", msg), UVM_HIGH)
      write_msg(msg);

      // if using KMAC, need to write either encoded output length or 0 to msgfifo
      if (kmac_en) begin
        right_encode(xof_en ? 0 : output_len * 8, output_len_enc);
        `uvm_info(`gfn, $sformatf("output_len_enc: %0p", output_len_enc), UVM_HIGH)
        write_msg(output_len_enc);
      end

      // issue Process cmd
      issue_cmd(CmdProcess);

      // wait for kmac_done to be set
      wait_for_kmac_done();

      // Read the output digest, scb will check digest
      read_digest_shares(output_len, cfg.enable_masking);

      // issue the Done cmd to tell KMAC to clear internal state
      issue_cmd(CmdDone);
      `uvm_info(`gfn, "done", UVM_HIGH)

      // TODO: randomly read out the digest after issuing Done command, expect both shares = 0

      // Drop the sideloaded key if it was provided to the DUT.
        //
      // TODO - wait a few clks before doing this so scb can check the digest.
      //        Remove this when the previous TODO(random read out digest) is implemented.
      cfg.clk_rst_vif.wait_clks(5);
      if (kmac_en && (en_sideload || provide_sideload_key)) begin
        cfg.sideload_vif.drive_sideload_key(0);
      end

    end

  endtask : body

endclass : kmac_smoke_vseq
