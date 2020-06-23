require "one_more_time"
require "timecop"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

ActiveRecord::Schema.define do
  create_table :idempotent_requests do |t|
    t.string "idempotency_key", null: false
    t.datetime "locked_at"
    t.text "request_path"
    t.text "request_body"
    t.text "response_code"
    t.text "response_body"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["idempotency_key"], name: "index_idempotent_requests_on_idempotency_key", unique: true
  end
end
