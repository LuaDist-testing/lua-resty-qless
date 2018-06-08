# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 1;

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_REDIS_PORT} ||= 6379;
$ENV{TEST_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/lib/?.lua;;";
    error_log logs/error.log debug;
    init_by_lua '
        cjson = require "cjson"
        redis_params = {
            host = "127.0.0.1",
            port = $ENV{TEST_REDIS_PORT},
            db = $ENV{TEST_REDIS_DATABASE}
        }

        -- Test task module, just sums numbers and logs the result.
        local sum = {}

        function sum.perform(job)
            local data = job.data
            if not data or #data == 0 then
                job:cancel()
                return nil
            end

            local sum = 0
            for _,v in ipairs(data) do
                sum = sum + v
            end

            ngx.log(ngx.NOTICE, "Sum: ", sum)
            return true
        end

        package.loaded["testtasks.sum"] = sum
    ';


    init_worker_by_lua '
        local Qless_Worker = require "resty.qless.worker"

        local worker = Qless_Worker.new(redis_params)

        worker:start({
            interval = 1,
            concurrency = 4,
            reserver = "ordered",
            queues = { "queue_14" },
        }) 


        local worker_mw = Qless_Worker.new(redis_params)

        worker_mw.middleware = function()
            ngx.log(ngx.NOTICE, "Middleware start")
            coroutine.yield()
            ngx.log(ngx.NOTICE, "Middleware stop")
        end

        worker_mw:start({
            queues = { "queue_15" },
        })
    ';
};

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Test a job runs and gets completed.
--- http_config eval: $::HttpConfig
--- config
    location = /1 {
        content_by_lua '
            local qless = require "resty.qless"
            local q = qless.new(redis_params)

            local jid = q.queues["queue_14"]:put("testtasks.sum", { 1, 2, 3, 4 })
            ngx.sleep(1)

            local job = q.jobs:get(jid)
            ngx.say(job.state)
        ';
    }
--- request
GET /1
--- response_body
complete
--- error_log eval
[qr/Sum: 10/]


=== TEST 2: Test middleware runs before and after job
--- http_config eval: $::HttpConfig
--- config
    location = /1 {
        content_by_lua '
            local qless = require "resty.qless"
            local q = qless.new(redis_params)

            local jid = q.queues["queue_15"]:put("testtasks.sum", { 1, 2, 3, 4 })
            ngx.sleep(1)

            local job = q.jobs:get(jid)
            ngx.say(job.state)
        ';
    }
--- request
GET /1
--- response_body
complete
--- error_log eval
[qr/Sum: 10/,
qr/Middleware stop/,
qr/Middleware start/]


=== TEST 3: Test a job can cancel itself if data is bad
--- http_config eval: $::HttpConfig
--- config
    location = /1 {
        content_by_lua '
            local qless = require "resty.qless"
            local q = qless.new(redis_params)

            local jid = q.queues["queue_14"]:put("testtasks.sum")
            ngx.sleep(1)

            local job = q.jobs:get(jid)
            if job then
                ngx.say(job.state)
            else
                ngx.say("canceled")
            end
        ';
    }
--- request
GET /1
--- response_body
canceled