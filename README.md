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

Generic solutions (i.e. drop-in Rack plugins) for idempotency do exist, however they can't handle requests that fail during processing very well because they don't know _when_ a request becomes unsafe to retry. If your endpoint itself only calls idempotent services, then retries are always safe and a generic solution will suffice.

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

## Usage

In order to guarantee idempotency, One More Time assumes a request can be divided into three phases:
1. The incoming request is stored in the local database and is validated.
2. State is changed in an external service (e.g. an order is submitted, a payment is made)
3. The results of step 2 are stored in the local database.

☝️ Note: This is the same pattern enforced by AirBnB's idempotency middleware (https://medium.com/airbnb-engineering/avoiding-double-payments-in-a-distributed-payments-system-2981f6b070bb).

Let's see how this looks in code. Imagine this is a rails controller.

```ruby

# We start off by getting an IdempotentRequest record similarly to Rails' create_or_find_by. When first created, the record is in a "locked" state so no other server process will be able to work on the same request.
idempotent_request = IdempotentRequest.start!(
  # This value is supplied by the client and is what uniquely identifies a request
  idempotency_key: request.headers["Idempotency-Key"],
  # If supplied, these values will be used to verify that the incoming request data matches the stored data (when a record with the given idempotency_key already exists).
  request_path: "#{request.method} #{request.path}",
  request_body: request.raw_post,
  )

# Tell the idempotent_request how to convert a successful result into response data stored on the record
idempotent_request.success_attributes do |result|
  {
    response_code: 200,
    response_body: result.to_json,
  }
end

# Similarly, convert an exception that has been raised into a stored response
idempotent_request.error_attributes do |exception|
  {
    response_code: 500,
    response_body: { error: exception.message }.to_json,
  }
end

# Everything up to this point should exist only once, as framework-level code in your app. Individual endpoint implementations should be provided with the idempotent_request object and only need to use the following pattern.

# Wrap your request in a block sent to the execute method. If the idempotent_request already has a stored response, the block will be skipped entirely.
idempotent_request.execute do
  # Make your external service call
  # widget = ExternalService.purchase_widget

  # Call the success! method with a block. The block is automatically run in a transaction and should contain any code needed to persist the results of your external service call.
  idempotent_request.success! do
    # The return value of this block is what gets passed to the success_attributes callback above
    # Widgets.create!(widget_id: widget.id)
  end
end

# Render the stored response
render json: idempotent_request.response_body, status: idempotent_request.response_code


```
🚨 **Note**: Do not call the normal ActiveRecord methods on an `IdempotentRequest`; only use the ones provided by One More Time. Doing the former will probably break functionality, and in the future `IdempotentRequest` might not be an ActiveRecord model anymore.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Freshly/one_more_time.

Todos:
- Add a rails generator to create a migration for the idempotent_requests table.
- Store a "client" attribute to prevent multiple API clients from colliding on `idempotency_key` values.
- Add example integations for different app frameworks.
  - Rails
  - Gruf
  - Sinatra
  - Grape

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
