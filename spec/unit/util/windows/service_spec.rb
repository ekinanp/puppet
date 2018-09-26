#!/usr/bin/env ruby
require 'spec_helper'

describe "Puppet::Util::Windows::Service", :if => Puppet.features.microsoft_windows? do
  require 'puppet/util/windows'

  before(:each) do
    Puppet::Util::Windows::Error.stubs(:format_error_code)
      .with(anything)
      .returns("fake error!")
  end

  def service_state_str(state)
    Puppet::Util::Windows::Service::SERVICE_STATES[state].to_s
  end

  # The following should emulate a successful call to the private function
  # query_status that returns the value of query_return. This should give
  # us a way to mock changes in service status.
  #
  # Everything else is stubbed, the emulation of the successful call is really
  # just an expectation of subject::SERVICE_STATUS_PROCESS.new in sequence that
  # returns the value passed in as a param
  def expect_successful_status_query_and_return(query_return)
    subject::SERVICE_STATUS_PROCESS.expects(:new).in_sequence(status_checks).returns(query_return)
  end

  def expect_successful_status_queries_and_return(*query_returns)
    query_returns.each do |query_return|
      expect_successful_status_query_and_return(query_return)
    end
  end

  # The following should emulate a successful call to the private function
  # query_config that returns the value of query_return. This should give
  # us a way to mock changes in service configuration.
  #
  # Everything else is stubbed, the emulation of the successful call is really
  # just an expectation of subject::QUERY_SERVICE_CONFIGW.new in sequence that
  # returns the value passed in as a param
  def expect_successful_config_query_and_return(query_return)
    subject::QUERY_SERVICE_CONFIGW.expects(:new).in_sequence(status_checks).returns(query_return)
  end

  let(:subject)      { Puppet::Util::Windows::Service }
  let(:pointer) { mock() }
  let(:status_checks) { sequence('status_checks') }
  let(:mock_service_name) { mock() }
  let(:service) { mock() }
  let(:scm) { mock() }

  before do
    subject.stubs(:QueryServiceStatusEx).returns(1)
    subject.stubs(:QueryServiceConfigW).returns(1)
    subject.stubs(:ChangeServiceConfigW).returns(1)
    subject.stubs(:OpenSCManagerW).returns(scm)
    subject.stubs(:OpenServiceW).returns(service)
    subject.stubs(:CloseServiceHandle)
    subject.stubs(:EnumServicesStatusExW).returns(1)
    subject.stubs(:wide_string)
    subject::SERVICE_STATUS_PROCESS.stubs(:new)
    subject::QUERY_SERVICE_CONFIGW.stubs(:new)
    subject::SERVICE_STATUS.stubs(:new).returns({:dwCurrentState => subject::SERVICE_RUNNING})
    FFI.stubs(:errno).returns(0)
    FFI::MemoryPointer.stubs(:new).yields(pointer)
    pointer.stubs(:read_dword)
    pointer.stubs(:write_dword)
    pointer.stubs(:size)
    subject.stubs(:sleep)
  end

  describe "#exists?" do
    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.exists?(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }

      it "returns false if it fails to open because the service does not exist" do
        FFI.stubs(:errno).returns(Puppet::Util::Windows::Service::ERROR_SERVICE_DOES_NOT_EXIST)

        expect(subject.exists?(mock_service_name)).to be false
      end

      it "raises a puppet error if it fails to open for some other reason" do
        expect{ subject.exists?(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do
      it "returns true" do
        expect(subject.exists?(mock_service_name)).to be true
      end
    end
  end

  # This shared example contains the unit tests for the send_service_control_signal
  # helper as used by service actions like #stop. Before including this example in
  # your tests, be sure to define the following variables in a `let` context:
  #     * signal        -- The service control signal to send
  #     * initial_state -- The service's initial state before sending the signal
  #     * final_state   -- The service's final state after sending the signal
  #
  shared_examples "a service action that sends a service control signal" do |action|
    it "raises a Puppet::Error if ControlService returns false" do
      expect_successful_status_query_and_return(dwCurrentState: initial_state)

      subject.stubs(:ControlService).with(service, signal, anything).returns(FFI::WIN32_FALSE)

      expect { subject.send(action, mock_service_name) }.to raise_error do |error|
        expect(error).to be_a(Puppet::Error)

        expect(error.message).to match(subject::SERVICE_CONTROL_SIGNALS[signal].to_s)
        expect(error.message).to match(service_state_str(initial_state))
      end
    end

    it "#{action}s the service" do
      expect_successful_status_queries_and_return(
        { dwCurrentState: initial_state },
        { dwCurrentState: final_state }
      )

      subject.expects(:ControlService).with(service, signal, anything).returns(1)

      subject.send(action, mock_service_name)
    end
  end

  # This shared example contains the unit tests for the wait_on_pending_state
  # helper as used by service actions like #start and #stop. Before including
  # this shared example, be sure to mock out any intermediate calls prior to
  # the pending transition, and make sure that the post-condition _after_ those
  # intermediate calls leaves the service in the pending state. Before including
  # this example in your tests, be sure to define the following variables in a `let`
  # context:
  #     * action -- The service action
  shared_examples "a service action waiting on a pending transition" do |pending_state|
    pending_state_str = Puppet::Util::Windows::Service::SERVICE_STATES[pending_state].to_s

    final_state = Puppet::Util::Windows::Service::FINAL_STATES[pending_state]
    final_state_str = Puppet::Util::Windows::Service::SERVICE_STATES[final_state].to_s

    it "raises a Puppet::Error if the service query fails" do
      subject.expects(:QueryServiceStatusEx).in_sequence(status_checks).returns(FFI::WIN32_FALSE)

      expect { subject.send(action, mock_service_name) }.to raise_error(Puppet::Error)
    end

    it "raises a Puppet::Error if the service unexpectedly transitions to a state other than #{pending_state_str} or #{final_state_str}" do
      invalid_state = (subject::SERVICE_STATES.keys - [pending_state, final_state]).first

      expect_successful_status_query_and_return(dwCurrentState: invalid_state)

      expect { subject.send(action, mock_service_name) }.to raise_error do |error|
        expect(error).to be_a(Puppet::Error)

        expect(error.message).to match(/[Uu]nexpected/)
        expect(error.message).to match(service_state_str(invalid_state))
        expect(error.message).to match(service_state_str(pending_state))
        expect(error.message).to match(service_state_str(final_state))
      end
    end

    it "waits for at least 1 second if the wait_hint/10 is < 1 second" do
      expect_successful_status_queries_and_return(
        { :dwCurrentState => pending_state, :dwWaitHint => 0, :dwCheckPoint => 1 },
        { :dwCurrentState => final_state }
      )

      subject.expects(:sleep).with(1)

      subject.send(action, mock_service_name)
    end

    it "waits for at most 10 seconds if wait_hint/10 is > 10 seconds" do
      expect_successful_status_queries_and_return(
        { :dwCurrentState => pending_state, :dwWaitHint => 1000000, :dwCheckPoint => 1 },
        { :dwCurrentState => final_state }
      )

      subject.expects(:sleep).with(10)

      subject.send(action, mock_service_name)
    end

    it "does not raise an error if the service makes any progress while transitioning to #{final_state_str}" do
      expect_successful_status_queries_and_return(
        # The three "pending_state" statuses simulate the scenario where the service
        # makes some progress during the transition right when Puppet's about to
        # time out.
        { :dwCurrentState => pending_state, :dwWaitHint => 100000, :dwCheckPoint => 1 },
        { :dwCurrentState => pending_state, :dwWaitHint => 100000, :dwCheckPoint => 1 },
        { :dwCurrentState => pending_state, :dwWaitHint => 100000, :dwCheckPoint => 2 },

        { :dwCurrentState => final_state }
      )

      expect { subject.send(action, mock_service_name) }.to_not raise_error
    end

    it "raises a Puppet::Error if it times out while waiting for the transition to #{final_state_str}" do
      expect_successful_status_queries_and_return(
        *([{ :dwCurrentState => pending_state, :dwWaitHint => 10000, :dwCheckPoint => 1 }] * 31)

        # Don't need to return anything else here, as at this point Puppet
        # should have timed out while waiting for the service.
      )

      expect { subject.send(action, mock_service_name) }.to raise_error do |error|
        expect(error).to be_a(Puppet::Error)

        expect(error.message).to match(/[Tt]imed/)
        expect(error.message).to match(service_state_str(pending_state))
        expect(error.message).to match(service_state_str(final_state))
      end
    end
  end

  # This shared example contains the unit tests for the transition_service_state
  # helper, which is the helper that all of our service actions like #start, #stop
  # delegate to. Including these tests under a shared example lets us include them in each of
  # those service action's unit tests. When including this shared example, be sure to
  # mock out any calls that perform the state transition. See, for example, the unit
  # tests for the #start method.
  #
  shared_examples "a service action that transitions the service state" do |action, valid_initial_states, pending_state, to_state|
    valid_initial_states_str = valid_initial_states.map do |state|
      Puppet::Util::Windows::Service::SERVICE_STATES[state]
    end.join(', ')
    pending_state_str = Puppet::Util::Windows::Service::SERVICE_STATES[pending_state].to_s
    to_state_str = Puppet::Util::Windows::Service::SERVICE_STATES[to_state].to_s

    it "raises a Puppet::Error if the service's initial state is not one of #{valid_initial_states_str}" do
      invalid_initial_state = (subject::SERVICE_STATES.keys - valid_initial_states).first
      expect_successful_status_query_and_return(dwCurrentState: invalid_initial_state)

      expect{ subject.send(action, mock_service_name) }.to raise_error do |error|
        expect(error).to be_a(Puppet::Error)

        expect(error.message).to match(valid_initial_states_str)
        expect(error.message).to match(service_state_str(invalid_initial_state))
      end
    end

    # If the service action accepts an unsafe pending state as one of the service's
    # initial states, then we need to test that the action waits for the service to
    # transition from that unsafe pending state before doing anything else.
    unsafe_pending_states = valid_initial_states & Puppet::Util::Windows::Service::UNSAFE_PENDING_STATES
    unless unsafe_pending_states.empty?
      unsafe_pending_state = unsafe_pending_states.first
      unsafe_pending_state_str = Puppet::Util::Windows::Service::SERVICE_STATES[unsafe_pending_state]

      context "waiting for a service with #{unsafe_pending_state_str} as its initial state" do
        # Here we set the service's initial state to the unsafe_pending_state
        before(:each) do
          # This mocks the status query to return the 'to_state' by default. Otherwise,
          # we will fail the tests in the latter parts of the code where we wait for the
          # service to finish transitioning to the 'to_state'.
          subject::SERVICE_STATUS_PROCESS.stubs(:new).returns(dwCurrentState: to_state)

          # This sets our service's initial state
          expect_successful_status_query_and_return(dwCurrentState: unsafe_pending_state)
        end

        include_examples "a service action waiting on a pending transition", unsafe_pending_state do
          let(:action) { action }
        end
      end
    end

    # reads e.g. "waiting for the service to transition to the SERVICE_RUNNING state after starting it"
    #
    # NOTE: This is really unit testing the wait_on_state_transition helper
    context "waiting for the service to transition to the #{to_state_str} state after executing the #{action} action" do
      # Choose an arbitrary initial state. We want to ensure that it does not
      # correspond to an unsafe pending state so we can simplify our mocking.
      # It is OK for us to do this here because we already have separate unit
      # tests for that behavior.
      let(:initial_state) do
        initial_states = (valid_initial_states - subject::UNSAFE_PENDING_STATES)

        initial_states.first
      end

      before(:each) do
        # This sets our service's initial state
        expect_successful_status_query_and_return(dwCurrentState: initial_state)
      end

      it "raises a Puppet::Error if the service query fails" do
        subject.expects(:QueryServiceStatusEx).in_sequence(status_checks).returns(FFI::WIN32_FALSE)

        expect { subject.send(action, mock_service_name) }.to raise_error(Puppet::Error)
      end

      it "waits, then queries again until it transitions to #{to_state_str}" do
        expect_successful_status_queries_and_return(
          { :dwCurrentState => initial_state },
          { :dwCurrentState => initial_state },
          { :dwCurrentState => to_state }
        )

        subject.expects(:sleep).with(1).twice

        subject.send(action, mock_service_name)
      end

      context "when it transitions to the #{pending_state_str} state" do
        before(:each) do
          expect_successful_status_query_and_return(dwCurrentState: pending_state)
        end

        include_examples "a service action waiting on a pending transition", pending_state do
          let(:action) { action }
        end
      end

      it "raises a Puppet::Error if it times out while waiting for the transition to #{to_state_str}" do
        31.times do
          expect_successful_status_query_and_return(dwCurrentState: initial_state)
        end

        expect { subject.send(action, mock_service_name) }.to raise_error do |error|
          expect(error).to be_a(Puppet::Error)

          expect(error.message).to match(/[Tt]ime/)
          expect(error.message).to match(service_state_str(initial_state))
          expect(error.message).to match(pending_state_str)
          expect(error.message).to match(to_state_str)
        end
      end
    end
  end

  describe "#start" do
    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.start(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.start(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do
      # Can't use rspec's subject here because that
      # can only be referenced inside an 'it' block.
      service = Puppet::Util::Windows::Service
      valid_initial_states = [service::SERVICE_STOP_PENDING, service::SERVICE_STOPPED]
      to_state = service::SERVICE_RUNNING
  
      include_examples "a service action that transitions the service state", :start, valid_initial_states, service::SERVICE_START_PENDING, to_state do
        before(:each) do
          subject.stubs(:StartServiceW).returns(1)
        end
      end
  
      it "raises a Puppet::Error if StartServiceW returns false" do
        expect_successful_status_query_and_return(dwCurrentState: subject::SERVICE_STOPPED)
  
        subject.expects(:StartServiceW).returns(FFI::WIN32_FALSE)

        expect { subject.start(mock_service_name) }.to raise_error do |error|
          expect(error).to be_a(Puppet::Error)
  
          expect(error.message).to match('start')
        end
      end
  
      it "starts the service" do
        expect_successful_status_queries_and_return(
          { dwCurrentState: subject::SERVICE_STOPPED },
          { dwCurrentState: subject::SERVICE_RUNNING }
        )
  
        subject.expects(:StartServiceW).returns(1)
  
        subject.start(mock_service_name)
      end
    end
  end

  describe "#stop" do
    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.start(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.start(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do
      service = Puppet::Util::Windows::Service
      valid_initial_states = service::SERVICE_STATES.keys - [service::SERVICE_STOP_PENDING, service::SERVICE_STOPPED]
      to_state = service::SERVICE_STOPPED
  
      include_examples "a service action that transitions the service state", :stop, valid_initial_states, service::SERVICE_STOP_PENDING, to_state do
        before(:each) do
          subject.stubs(:ControlService).returns(1)
        end
      end
  
      include_examples "a service action that sends a service control signal", :stop do
        let(:signal)        { subject::SERVICE_CONTROL_STOP }

        let(:initial_state) { subject::SERVICE_RUNNING }
        let(:final_state)   { subject::SERVICE_STOPPED }
      end
    end
  end

  describe "#service_state" do
    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.service_state(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.service_state(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do
      it "raises Puppet::Error if the result of the query is empty" do
        expect_successful_status_query_and_return({})
        expect{subject.service_state(mock_service_name)}.to raise_error(Puppet::Error)
      end

      it "raises Puppet::Error if the result of the query is an unknown state" do
        expect_successful_status_query_and_return({:dwCurrentState => 999})
        expect{subject.service_state(mock_service_name)}.to raise_error(Puppet::Error)
      end

      # We need to guard this section explicitly since rspec will always
      # construct all examples, even if it isn't going to run them.
      if Puppet.features.microsoft_windows?
        {
          :SERVICE_STOPPED => Puppet::Util::Windows::Service::SERVICE_STOPPED,
          :SERVICE_PAUSED => Puppet::Util::Windows::Service::SERVICE_PAUSED,
          :SERVICE_STOP_PENDING => Puppet::Util::Windows::Service::SERVICE_STOP_PENDING,
          :SERVICE_PAUSE_PENDING => Puppet::Util::Windows::Service::SERVICE_PAUSE_PENDING,
          :SERVICE_RUNNING => Puppet::Util::Windows::Service::SERVICE_RUNNING,
          :SERVICE_CONTINUE_PENDING => Puppet::Util::Windows::Service::SERVICE_CONTINUE_PENDING,
          :SERVICE_START_PENDING => Puppet::Util::Windows::Service::SERVICE_START_PENDING,
        }.each do |state_name, state|
          it "queries the service and returns #{state_name}" do
            expect_successful_status_query_and_return({:dwCurrentState => state})
            expect(subject.service_state(mock_service_name)).to eq(state_name)
          end
        end
      end
    end
  end

  describe "#service_start_type" do
    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.service_start_type(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.service_start_type(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do

      # We need to guard this section explicitly since rspec will always
      # construct all examples, even if it isn't going to run them.
      if Puppet.features.microsoft_windows?
        {
          :SERVICE_AUTO_START => Puppet::Util::Windows::Service::SERVICE_AUTO_START,
          :SERVICE_BOOT_START => Puppet::Util::Windows::Service::SERVICE_BOOT_START,
          :SERVICE_SYSTEM_START => Puppet::Util::Windows::Service::SERVICE_SYSTEM_START,
          :SERVICE_DEMAND_START => Puppet::Util::Windows::Service::SERVICE_DEMAND_START,
          :SERVICE_DISABLED => Puppet::Util::Windows::Service::SERVICE_DISABLED,
        }.each do |start_type_name, start_type|
          it "queries the service and returns the service start type #{start_type_name}" do
            expect_successful_config_query_and_return({:dwStartType => start_type})
            expect(subject.service_start_type(mock_service_name)).to eq(start_type_name)
          end
        end
      end
      it "raises a puppet error if the service query fails" do
        subject.expects(:QueryServiceConfigW).in_sequence(status_checks)
        subject.expects(:QueryServiceConfigW).in_sequence(status_checks).returns(FFI::WIN32_FALSE)
        expect{ subject.service_start_type(mock_service_name) }.to raise_error(Puppet::Error)
      end
    end
  end

  describe "#set_startup_mode" do
    let(:status_checks) { sequence('status_checks') }

    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.set_startup_mode(mock_service_name, :SERVICE_DEMAND_START) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service cannot be opened" do
      let(:service) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.set_startup_mode(mock_service_name, :SERVICE_DEMAND_START) }.to raise_error(Puppet::Error)
      end
    end

    context "when the service can be opened" do
      it "Raises an error on an unsuccessful change" do
        subject.expects(:ChangeServiceConfigW).returns(FFI::WIN32_FALSE)
        expect{ subject.set_startup_mode(mock_service_name, :SERVICE_DEMAND_START) }.to raise_error(Puppet::Error)
      end
    end
  end

  describe "#services" do
    let(:pointer_sequence) { sequence('pointer_sequence') }

    context "when the service control manager cannot be opened" do
      let(:scm) { FFI::Pointer::NULL_HANDLE }
      it "raises a puppet error" do
        expect{ subject.services }.to raise_error(Puppet::Error)
      end
    end

    context "when the service control manager is open" do
      let(:cursor) { [ 'svc1', 'svc2', 'svc3' ] }
      let(:svc1name_ptr) { mock() }
      let(:svc2name_ptr) { mock() }
      let(:svc3name_ptr) { mock() }
      let(:svc1displayname_ptr) { mock() }
      let(:svc2displayname_ptr) { mock() }
      let(:svc3displayname_ptr) { mock() }
      let(:svc1) { { :lpServiceName => svc1name_ptr, :lpDisplayName => svc1displayname_ptr, :ServiceStatusProcess => 'foo' } }
      let(:svc2) { { :lpServiceName => svc2name_ptr, :lpDisplayName => svc2displayname_ptr, :ServiceStatusProcess => 'foo' } }
      let(:svc3) { { :lpServiceName => svc3name_ptr, :lpDisplayName => svc3displayname_ptr, :ServiceStatusProcess => 'foo' } }

      it "Raises an error if EnumServicesStatusExW fails" do
        subject.expects(:EnumServicesStatusExW).in_sequence(pointer_sequence)
        subject.expects(:EnumServicesStatusExW).in_sequence(pointer_sequence).returns(FFI::WIN32_FALSE)
        expect{ subject.services }.to raise_error(Puppet::Error)
      end

      it "Reads the buffer using pointer arithmetic to create a hash of service entries" do
        # the first read_dword is for reading the bytes required, let that return 3 too.
        # the second read_dword will actually read the number of services returned
        pointer.expects(:read_dword).twice.returns(3)
        FFI::Pointer.expects(:new).with(subject::ENUM_SERVICE_STATUS_PROCESSW, pointer).returns(cursor)
        subject::ENUM_SERVICE_STATUS_PROCESSW.expects(:new).in_sequence(pointer_sequence).with('svc1').returns(svc1)
        subject::ENUM_SERVICE_STATUS_PROCESSW.expects(:new).in_sequence(pointer_sequence).with('svc2').returns(svc2)
        subject::ENUM_SERVICE_STATUS_PROCESSW.expects(:new).in_sequence(pointer_sequence).with('svc3').returns(svc3)
        svc1name_ptr.expects(:read_arbitrary_wide_string_up_to).returns('svc1')
        svc2name_ptr.expects(:read_arbitrary_wide_string_up_to).returns('svc2')
        svc3name_ptr.expects(:read_arbitrary_wide_string_up_to).returns('svc3')
        svc1displayname_ptr.expects(:read_arbitrary_wide_string_up_to).returns('service 1')
        svc2displayname_ptr.expects(:read_arbitrary_wide_string_up_to).returns('service 2')
        svc3displayname_ptr.expects(:read_arbitrary_wide_string_up_to).returns('service 3')
        expect(subject.services).to eq({
          'svc1' => { :display_name => 'service 1', :service_status_process => 'foo' },
          'svc2' => { :display_name => 'service 2', :service_status_process => 'foo' },
          'svc3' => { :display_name => 'service 3', :service_status_process => 'foo' }
        })
      end
    end
  end
end
