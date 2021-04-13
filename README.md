# One More Time

A Ruby/ActiveRecord solution for idempotency.
Because it should always be safe to call your API... _one more time_.

* [When to use](#when-to-use)
* [Installation](#installation)
* [Usage](#usage)
* [Example Code](#example-code)
* [Contributing](#contributing)
* [License](#license)

## When to use

One More time is a good choice if...

* You are implementing an API for which idempotency is a concern

AND...

* You can add a new table to your local ACID datastore

AND at least one of the following is true...

* You have multiple endpoints that need to be idempotent and you want to use a shared solution for them.
* Your endpoint invokes a third-party service that does _not_ provide idempotency.
* A more generic solution (that has to eagerly prohibit retries) won't cut it; you want to minimize manual intervention when things go wrong.


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'one_more_time'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install one_more_time

Then create a table in your database named `idempotent_requests` with, at minimum, the following columns (a generator for this is in the TODO list):

| Name            | ActiveRecord Type |
|-----------------|-------------
| idempotency_key | string / text (with UNIQUE constraint)
| locked_at       | datetime
| request_body    | (any)
| request_path    | (any)
| response_code   | (any)
| response_body   | (any)

🚨 **Note**: The idempotency_key column MUST have a unique constraint.

## Usage

The gem provides a single factory method: `OneMoreTime.start_request!`. You use the returned object to orchestrate the endpoint you are implementing, and by doing so you are guaranteed idempotency.

This is based on the assumption that your endpoint can be divided into three steps:
1. Validate the incoming request and record it in the local database.
2. Do the things that MUST NOT happen more than once; often that means changing state in an external service (e.g. submit an order, make a payment)
3. Record the results of step 2 in the local database.

Step 1 is what actually guarantees idempotency, and `OneMoreTime.start_request!` does it for you. Then it helps you organize steps 2 and 3.

 > For more in-depth reading, this is the same pattern enforced by AirBnB's idempotency middleware (https://medium.com/airbnb-engineering/avoiding-double-payments-in-a-distributed-payments-system-2981f6b070bb).

One More Time is intended as middleware and does not know about the procotol being used; it only provides storage for request and response data. Thus you will need to tell the gem how to store incoming requests, as well as how to convert stored responses into the response data you need. 

## Example Code

You will typically write some framework-level code once, so One More Time knows how to access and interpret an incoming request.

This might look like the following as a helper method on a Rails controller:

```ruby
def start_idempotent_request!
  # We begin by calling OneMoreTime.start_request!, which creates (or finds an existing) 
  # request using the given idempotency_key, and returns a record representing it.
  
  # When first created, the record is in a "locked" state so no other server process 
  # will be able to work on the same request. If we found an existing locked record, 
  # a RequestInProgressError will be raised.

  idempotent_request = OneMoreTime.start_request!(
    # This value is supplied by the client, who decides the scope of idempotency
    idempotency_key: request.headers["Idempotency-Key"],
    # If supplied, these values will be used to verify that the incoming request data match
    # the stored data (when an existing record was found). If there is a mismatch, a 
    # RequestMismatchError will be raised.
    request_path: "#{request.method} #{request.path}",
    request_body: request.raw_post,
    )

  # Set a callback to specify how to convert a successful result into response data stored
  # on the record
  idempotent_request.success_attributes do |result|
    {
      response_code: 200,
      response_body: result.to_json,
    }
  end

  # Similarly, convert an exception that has been raised into a stored response
  idempotent_request.failure_attributes do |exception|
    {
      response_code: 500,
      response_body: { error: exception.message }.to_json,
    }
  end

  idempotent_request
end
```

Individual endpoint implementations would then use the following pattern:

```ruby
idempotent_request = start_idempotent_request!

# Wrap your code in a block sent to the execute method. 
# This block will be skipped entirely if any of the following apply:
# - Another process is currently running it
# - It has previously run and completed
# - It has previously run and it is not 100% certain how far it got
idempotent_request.execute do

  # While inside the execute block, raising an error will by default unlock the request, so 
  # the block can be retried by a later process.
  raise RetryableError unless ExternalService.service_is_online?

  # But now we need to make an external, non-idempotent service call
  begin
    widget = ExternalService.purchase_widget(params[:widget_name])
  rescue ExternalService::ConnectionLostError => exception
  #   We sent data to the external service but don't know whether it was fully processed.
  #   If a widget is something we can't afford to accidentally create twice, we need to
  #   give up and store an error response on this request so it can't be retried.
  #   This will invoke the failure_attributes callback and raise out of the execute block.
    idempotent_request.failure!(exception: exception)
  end

  # Call the success method with a block. This block is automatically run in a transaction
  # and should contain any code needed to persist the results of your external service call.
  # Any failure within this block will internally call failure! on the request - we DID
  # purchase a widget already, so we can't allow a retry.
  idempotent_request.success do
    # The return value of this block is what gets passed to the success_attributes callback
    Widget.create!(widget_id: widget.id)
  end
end

# Render the stored response, which we are guaranteed to have if we make it here
render json: idempotent_request.response_body, status: idempotent_request.response_code
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Freshly/one_more_time.

Todos/Enhancements:
- Add a rails generator to create a migration for the idempotent_requests table.
- Add example integations for different app frameworks.
  - Rails
  - Gruf
- Add a method that marks the request as "unsafe". Thereafter, any exception raised would call `failure!`. This would be called before changing state in any external system.
- Look into supporting recovery points/multiple transactions per request.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
