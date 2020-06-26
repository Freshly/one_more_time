# One More Time

A simple gem to help make your API idempotent.
Because it should always be safe to call your API... _one more time_.

* [Overview](#overview)
* [Installation](#installation)
* [Usage](#usage)
* [Contributing](#contributing)
* [License](#license)

## Overview

As a library for idempotency, One More Time serves two main purposes:
- Saving and returning the previous response to a repeated request
- Ensuring side effects that should only happen once (e.g. paying money) in fact only happen once

To accomplish these, this gem provides a single ActiveRecord model called `IdempotentRequest` with some additional methods added. You call those methods at specific points in the lifecycle of your request, and idempotency is guaranteed for you.

Generic solutions (i.e. drop-in Rack plugins) for idempotency do exist, however they can't handle requests that fail during processing very well because they don't know _when_ a request becomes unsafe to retry. If there's nothing you're afraid to retry when your request is left in an undefined state, a generic solution will suffice.

🚨 **Note**: One More Time is intended as middleware and does not know about the network procotol being used; it only provides dumb storage for request and response data. Thus you will need to tell the gem how to store incoming requests, as well as how to convert stored responses into actual responses at the network level. The goal would be to write this glue code once for a given Ruby application framework (e.g. Rails controllers, Gruf, Sinatra) and then re-use it thereafter.

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

🚨 **Note**: The idempotency_key column MUST have a unique constraint for the gem to work.

## Usage

In order to guarantee idempotency, One More Time assumes a request can be divided into three phases:
1. The incoming request is stored in the local database and is validated. Any read-only queries or service calls are made.
2. State is changed in an external service (e.g. an order is submitted, a payment is made)
3. The results of step 2 are stored in the local database.

☝️ Note: For more in-depth reading, this is the same pattern enforced by AirBnB's idempotency middleware (https://medium.com/airbnb-engineering/avoiding-double-payments-in-a-distributed-payments-system-2981f6b070bb).

Let's see how this looks in code, for example in a rails controller:
```ruby
# We begin by calling OneMoreTime.start_request!, which either creates or finds a record
# using the given idempotency_key. The record (for now an ActiveRecord model but don't rely
# on that) has methods to help orchestrate your request.
# When first created, the record is in a "locked" state so no other server process will be
# able to work on the same request. If we try to access a locked record here, a
# RequestInProgressError will be raised.
idempotent_request = OneMoreTime.start_request!(
  # This value is supplied by the client, who decides the scope of idempotency
  idempotency_key: request.headers["Idempotency-Key"],
  # If supplied, these values will be used to verify that the incoming request data matches
  # the stored data (when a record with the given idempotency_key already exists).
  # If there is a mismatch, a RequestMismatchError will be raised.
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
```

Everything up to this point will likely occur only once, as framework-level code in your app. Individual endpoint implementations should be provided with the `idempotent_request` object and only need to use the following pattern:

```ruby
# Wrap your request in a block sent to the execute method. If the idempotent_request already
# has a stored response, the block will be skipped entirely.
idempotent_request.execute do
  # Validate the request as needed.
  # Because we are inside the execute block, raising an error will automatically unlock the
  # request and NOT store a response, so this block can be retried by the next attempt.
  raise ActionController::BadRequest unless params[:widget_name].present?

  # Make an external, non-idempotent service call
  begin
    widget = ExternalService.purchase_widget(params[:widget_name])
  rescue ExternalService::ConnectionLostError => exception
  #   We sent data to the external service but don't know whether it was fully processed.
  #   If a widget is something we can't afford to accidentally create twice, we need to
  #   give up and store an error response on this request so it can't be retried.
  #   This will invoke the failure_attributes callback and raise out of the execute block.
    idempotent_request.failure!(exception: exception)
  end

  # Call the success! method with a block. This block is automatically run in a transaction
  # and should contain any code needed to persist the results of your external service call.
  # Any failure within this block will internally call failure! on the request - we've
  # failed to store a record of the widget, but we DID purchase it, so we can't allow a retry.
  idempotent_request.success do
    # The return value of this block is what gets passed to the success_attributes callback
    Widget.create!(widget_id: widget.id)
  end
end

# Render the stored response, which we are guaranteed to have if we make it here
render json: idempotent_request.response_body, status: idempotent_request.response_code

# And that's it!
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Freshly/one_more_time.

Todos/Enhancements:
- Add a rails generator to create a migration for the idempotent_requests table.
- Add example integations for different app frameworks.
  - Rails
  - Gruf
  - Sinatra
- Possibly add another yielding method that calls `failure!` by default for any exception. When using this method, instead of rescuing errors that are _not_ retryable and calling `failure!` yourself, you would explicitly rescue exceptions that _are_ retryable.
- Look into supporting recovery points/multiple transactions per request.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
