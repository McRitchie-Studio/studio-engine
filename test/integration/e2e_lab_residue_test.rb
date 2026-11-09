# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "fileutils"
require "net/http"
require "rbconfig"
require "socket"
require "tmpdir"

# [integration] THE ENGINE LAB LEAVES NO FILE IN THE DUMMY'S PUBLIC FOLDER.
#
# THE INCIDENT. e2e/boot.rb wrote favicon.png (and public/e2e/*, and the state
# flags) into test/dummy/public. That folder is the public folder of the minitest
# suite too, and it is ignored, so `git status` never showed the file. After a
# local lab run, HeadScriptNonceTest's "bare without the file" half read the
# lab's favicon and went red in the submit pre-flight. On 2026-11-09 two builders
# (the site-identity and anchor-scroll tasks) each lost a submit cycle to it.
#
# WHAT THIS PROVES. The real boot script runs as its own process, serves the lab
# (the favicon request still succeeds, which is why the lab writes one), and is
# then stopped with SIGKILL: the harshest end a run can have, because no exit
# handler runs. After that, test/dummy/public holds no file the boot added, and
# none of the paths the old lab wrote. A clean-up-on-exit fix fails this test;
# only a lab that never writes into the folder passes it.
#
# A SNAPSHOT, NOT A COMPARISON WITH GIT. Git tracks nothing in that folder, but
# three other suites (marketing_kit, link_preview, public_user_page) write a file
# there and remove it in teardown. An interrupted run of one of them is not the
# lab's residue, so this test compares the folder with itself before the boot.
#
# E2E_LAB_ROOT points the boot at a temporary folder, so this test does not
# clear the folder or the database of a lab that a builder is running.
class E2eLabResidueTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DUMMY_PUBLIC = File.join(ROOT, "test", "dummy", "public")
  BOOT_DEADLINE = 240 # seconds; the first boot compiles Tailwind.
  # What the lab wrote into test/dummy/public before it had its own folder.
  LAB_WRITTEN = %w[favicon.png e2e images/state-flags].freeze

  def test_a_killed_lab_run_leaves_the_dummy_public_folder_as_git_has_it
    before = files_in_dummy_public
    Dir.mktmpdir("e2e-lab-residue") do |lab_root|
      log = File.join(lab_root, "boot.log")
      port = free_port
      pid = Process.spawn(
        { "E2E_PORT" => port.to_s, "E2E_LAB_ROOT" => lab_root, "RAILS_ENV" => "test" },
        RbConfig.ruby, File.join("e2e", "boot.rb"),
        chdir: ROOT, out: log, err: log
      )
      begin
        wait_until_serving(pid, port, log)

        favicon = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/favicon.png"))
        assert_equal "200", favicon.code, "the lab must still serve a favicon: a 404 is console noise to every spec"
        assert_equal "200", Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/e2e/tailwind.css")).code,
                     "the lab must still serve its compiled CSS"

        assert_empty files_in_dummy_public - before,
                     "the running lab wrote into test/dummy/public, the minitest suite's public folder"
      ensure
        stop(pid)
      end

      assert_empty files_in_dummy_public - before,
                   "a killed lab run left files in test/dummy/public; they redden HeadScriptNonceTest"
      LAB_WRITTEN.each do |path|
        refute File.exist?(File.join(DUMMY_PUBLIC, path)), "test/dummy/public/#{path} outlived the lab"
      end
    end
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Polls the lab's own /up route until it answers, the boot process dies, or
  # the deadline passes. Each failure names the boot log.
  def wait_until_serving(pid, port, log)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_DEADLINE
    loop do
      if Process.waitpid(pid, Process::WNOHANG)
        flunk "e2e/boot.rb exited before it served (status #{$?.exitstatus}):\n#{File.read(log)}"
      end
      begin
        return if Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).code == "200"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
        # Not listening yet.
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "e2e/boot.rb did not serve /up within #{BOOT_DEADLINE}s:\n#{File.read(log)}"
      end
      IO.select(nil, nil, nil, 0.25)
    end
  end

  # SIGKILL by PID, then reap it, so no lab process outlives the test.
  def stop(pid)
    Process.kill("KILL", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # Already gone and reaped.
  end

  def files_in_dummy_public
    Dir.glob(File.join(DUMMY_PUBLIC, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .map { |path| path.delete_prefix("#{ROOT}/") }
       .sort
  end
end
