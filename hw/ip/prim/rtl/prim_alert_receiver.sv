// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The alert receiver primitive decodes alerts that have been differentially
// encoded and transmitted via a handshake protocol on alert_pi/ni and
// ack_po/no. In case an alert handshake is initiated, the output alert_o will
// immediately be asserted (even before completion of the handshake).
//
// In case the differential input is not correctly encoded, this module will
// raise an error by asserting integ_fail_o.
//
// Further, the module supports ping testing of the alert diff pair. In order to
// initiate a ping test, ping_en_i shall be set to 1'b1 until ping_ok_o is
// asserted for one cycle. The signal may be de-asserted (e.g. after a long)
// timeout period. However note that all ping responses that come in after
// deasserting ping_en_i will be treated as native alerts.
//
// The protocol works in both asynchronous and synchronous cases. In the
// asynchronous case, the parameter AsyncOn must be set to 1'b1 in order to
// instantiate additional synchronization logic. Further, it must be ensured
// that the timing skew between all diff pairs is smaller than the shortest
// clock period of the involved clocks.
//
// Note that in case of synchronous operation, alerts on the diffpair are
// decoded combinationally and forwarded on alert_o within the same cycle.
//
// See also: prim_alert_sender, prim_diff_decode, alert_handler

module prim_alert_receiver #(
  // enables additional synchronization logic
  parameter bit AsyncOn = 1'b0
) (
  input        clk_i,
  input        rst_ni,
  // this triggers a ping test. keep asserted
  // until ping_ok_o is asserted.
  input        ping_en_i,
  output logic ping_ok_o,
  // asserted if signal integrity issue detected
  output logic integ_fail_o,
  // alert output (pulsed high) if a handshake is initiated
  // on alert_p/n and no ping request is outstanding
  output logic alert_o,
  // ping output diff pair
  output logic ping_po,
  output logic ping_no,
  // ack output diff pair
  output logic ack_po,
  output logic ack_no,
  // alert input diff pair
  input        alert_pi,
  input        alert_ni
);


  /////////////////////////////////
  // decode differential signals //
  /////////////////////////////////
  logic alert_level, alert_sigint;

  prim_diff_decode #(
    .AsyncOn(AsyncOn)
  ) i_decode_alert (
    .clk_i,
    .rst_ni,
    .diff_pi  ( alert_pi     ),
    .diff_ni  ( alert_ni     ),
    .level_o  ( alert_level  ),
    .rise_o   (              ),
    .fall_o   (              ),
    .event_o  (              ),
    .sigint_o ( alert_sigint )
  );

  /////////////////////////////////////////////////////
  //  main protocol FSM that drives the diff outputs //
  /////////////////////////////////////////////////////
  typedef enum logic [1:0] {Idle, HsAckWait, Pause0, Pause1} state_e;
  state_e state_d, state_q;
  logic ping_rise;
  logic ping_tog_d, ping_tog_q, ack_d, ack_q;
  logic ping_en_d, ping_en_q;
  logic ping_pending_d, ping_pending_q;

  // signal ping request upon positive transition on ping_en_i
  // signalling is performed by a level change event on the diff output
  assign ping_en_d  = ping_en_i;
  assign ping_rise  = ping_en_i && !ping_en_q;
  assign ping_tog_d = (ping_rise) ? ~ping_tog_q : ping_tog_q;

  // the ping pending signal is used to in the FSM to distinguish whether the
  // incoming handshake shall be treated as an alert or a ping response.
  // it is important that this is only set on a rising ping_en level change, since
  // otherwise the ping enable signal could be abused to "mask" all native alerts
  // as ping responses by constantly tying it to 1.
  assign ping_pending_d = ping_rise | ((~ping_ok_o) & ping_en_i & ping_pending_q);

  // diff pair outputs
  assign ack_po  = ack_q;
  assign ack_no  = ~ack_q;
  assign ping_po = ping_tog_q;
  assign ping_no = ~ping_tog_q;

  // this FSM receives the four phase handshakes from the alert receiver
  // note that the latency of the alert_p/n input diff pair is at least one
  // cycle until it enters the receiver FSM. the same holds for the ack_* diff
  // pair outputs.
  always_comb begin : p_fsm
    // default
    state_d      = state_q;
    ack_d        = 1'b0;
    ping_ok_o    = 1'b0;
    integ_fail_o = 1'b0;
    alert_o      = 1'b0;

    unique case (state_q)
      Idle: begin
        // wait for handshake to be initiated
        if (alert_level) begin
          state_d = HsAckWait;
          ack_d   = 1'b1;
          // signal either an alert or ping received on the output
          if (ping_pending_q) begin
            ping_ok_o = 1'b1;
          end else begin
            alert_o   = 1'b1;
          end
        end
      end
      // waiting for deassertion of alert to complete HS
      HsAckWait: begin
        if (!alert_level) begin
          state_d  = Pause0;
        end else begin
          ack_d    = 1'b1;
        end
      end
      // pause cycles between back-to-back handshakes
      Pause0: state_d = Pause1;
      Pause1: state_d = Idle;
      default : ; // full case
    endcase

    // override in case of sigint
    if (alert_sigint) begin
      state_d      = Idle;
      ack_d        = 1'b0;
      ping_ok_o    = 1'b0;
      integ_fail_o = 1'b1;
      alert_o      = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_reg
    if (!rst_ni) begin
      state_q        <= Idle;
      ack_q          <= 1'b0;
      ping_tog_q     <= 1'b0;
      ping_en_q      <= 1'b0;
      ping_pending_q <= 1'b0;
    end else begin
      state_q        <= state_d;
      ack_q          <= ack_d;
      ping_tog_q     <= ping_tog_d;
      ping_en_q      <= ping_en_d;
      ping_pending_q <= ping_pending_d;
    end
  end


  ////////////////
  // assertions //
  ////////////////

  // check whether all outputs have a good known state after reset
  `ASSERT_KNOWN(PingOkKnownO_A, ping_ok_o, clk_i, !rst_ni)
  `ASSERT_KNOWN(IntegFailKnownO_A, integ_fail_o, clk_i, !rst_ni)
  `ASSERT_KNOWN(AlertKnownO_A, alert_o, clk_i, !rst_ni)
  `ASSERT_KNOWN(PingPKnownO_A, ping_po, clk_i, !rst_ni)
  `ASSERT_KNOWN(PingNKnownO_A, ping_no, clk_i, !rst_ni)
  `ASSERT_KNOWN(AckPKnownO_A, ack_po, clk_i, !rst_ni)
  `ASSERT_KNOWN(AckNKnownO_A, ack_no, clk_i, !rst_ni)

  // check encoding of outgoing diffpairs
  `ASSERT(PingDiffOk_A, ping_po ^ ping_no, clk_i, !rst_ni)
  `ASSERT(AckDiffOk_A, ack_po ^ ack_no, clk_i, !rst_ni)
  // ping request at input -> need to see encoded ping request
  `ASSERT(PingRequest0_A, ##1 $rose(ping_en_i) |=> $changed(ping_po), clk_i, !rst_ni)
  // ping response implies it has been requested
  `ASSERT(PingResponse0_A, ping_ok_o |-> ping_pending_q, clk_i, !rst_ni)
  // correctly latch ping request
  `ASSERT(PingPending_A, ##1 $rose(ping_en_i) |=> ping_pending_q, clk_i, !rst_ni)

  if (AsyncOn) begin : gen_async_assert
    // signal integrity check propagation
    `ASSERT(SigInt_A, alert_pi == alert_ni [*2] |-> ##2 integ_fail_o, clk_i, !rst_ni)
    // TODO: need to add skewed cases as well, the assertions below assume no skew at the moment
    // ping response
    `ASSERT(PingResponse1_A, ##1 $rose(alert_pi) && (alert_pi ^ alert_ni) ##2
        state_q == Idle && ping_pending_q |-> ping_ok_o, clk_i, !rst_ni || integ_fail_o)
    // alert
    `ASSERT(Alert_A, ##1 $rose(alert_pi) && (alert_pi ^ alert_ni) ##2
        state_q == Idle && !ping_pending_q |-> alert_o, clk_i, !rst_ni || integ_fail_o)
  end else begin : gen_sync_assert
    // signal integrity check propagation
    `ASSERT(SigInt_A, alert_pi == alert_ni |-> integ_fail_o, clk_i, !rst_ni)
    // ping response
    `ASSERT(PingResponse1_A, ##1 $rose(alert_pi) && state_q == Idle && ping_pending_q |->
        ping_ok_o, clk_i, !rst_ni || integ_fail_o)
    // alert
    `ASSERT(Alert_A, ##1 $rose(alert_pi) && state_q == Idle && !ping_pending_q |->
        alert_o, clk_i, !rst_ni || integ_fail_o)
  end

endmodule : prim_alert_receiver
