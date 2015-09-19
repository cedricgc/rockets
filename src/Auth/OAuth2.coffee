###
Used to make authenticated requests to the reddit API. Responsible for:
  - Requesting an access token
  - Making sure the reddit rate-limit rules are followed
  - Making authenticated requests to the API

See https://github.com/reddit/reddit/wiki/OAuth2
###
module.exports = class OAuth2

  constructor: () ->
    @rate = new RateLimiter()
    @token = null


  # Wraps authentication around a callback which expects an access token.
  authenticate: (callback) ->

    # Use the current token if it's still valid.
    if @token and not @token.hasExpired()
      return callback(@token)

    log.info {
      event: 'token.request'
    }

    options =
      url: 'https://www.reddit.com/api/v1/access_token'
      method: 'POST'
      auth:
        user: process.env.CLIENT_ID
        pass: process.env.CLIENT_SECRET
      form:
        grant_type: 'client_credentials'
        username: process.env.USERNAME
        password: process.env.PASSWORD

    # Request a new access token
    request options, (error, response, body) =>
      if response?.statusCode is 200
        try
          @token = new AccessToken JSON.parse(body)

          log.info {
            event: 'token.created'
            token: @token.access_token
          }

        catch exception
          log.error {
            message: 'Unexpected access token JSON response'
            body: body
          }

      else
        log.error {
          message: 'Unexpected status code for access token request'
          status: response?.statusCode
        }

      callback(@token)


  # Requests models from reddit.com using given request parameters.
  # Passes models to a handler or `false` if the request was unsuccessful.
  models: (parameters, handler) ->

    log.info {
      event: 'request.models'
      parameters: parameters
    }

    @authenticatedRequest parameters, (error, response, body) ->

      if response?.statusCode isnt 200
        log.error {
          message: 'Unexpected status code for model request'
          status: response?.statusCode
        }

        return handler()

      # Attempt to parse the response JSON
      try
        parsed = JSON.parse(body)

      catch exception
        log.error {
          message: 'Failed to parse JSON response'
          exception: exception,
          body: body
        }

        return handler()

      # Make sure that the parsed JSON is also in the expected format, which
      # should be a standard reddit 'Listing'.
      if parsed.data and 'children' of parsed.data

        # reddit doesn't always send results in the right order. This will
        # sort the models by ascending ID, ie. from oldest to newest.
        children = parsed.data.children.sort (a, b) ->
          return parseInt(a.data.id, 36) - parseInt(b.data.id, 36)

        log.info {
          event: 'request.models.received'
          count: children.length
        }

        return handler(children)

      else
        log.error {
          message: 'No children found in parsed JSON response'
        }

        return handler()


  # Attempts to set the allowed rate limit using a response
  setRateLimit: (response) ->
    if response?.headers
      try
        messages = response.headers['x-ratelimit-remaining']
        seconds  = response.headers['x-ratelimit-reset']

        @rate.setRate(messages, seconds)

        log.info {
          event: 'ratelimit'
          messages: messages
          seconds: seconds
        }

      catch exception
        message = 'Failed to set rate limit'

        log.error {
          message: 'Failed to set rate limit'
          headers: response.headers
          exception: exception
        }


  # Adds a new request to the rate limit queue, where handler expects parameters
  # error, response, and body.
  enqueueRequest: (parameters, handler) ->

    # Schedule a request on the rate limit queue
    @rate.push (next) =>

      log.info {
        event: 'request'
        parameters: parameters
      }

      try
        return request parameters, (error, response, body) =>


          if error
            log.error {
              message: 'Unexpected request error'
              status: response?.statusCode
              error: error
            }


          log.info {
            event: 'ratelimit.set.before'
            headers: response?.headers
          }

          # Set the rate limit allowance using the reddit rate-limit headers.
          # See https://www.reddit.com/1yxrp7
          @setRateLimit(response)

          log.info {
            event: 'ratelimit.set.after'
            headers: response?.headers
          }

          # Trying to determine where we're stalling
          log.info {
            event: 'request.try.handler'
            headers: response?.headers
          }

          try

             # Trying to determine where we're stalling
            log.info {
              event: 'request.call.handler'
              headers: response?.headers
            }

            handler(error, response, body)

            # Trying to determine where we're stalling
            log.info {
              event: 'request.after.handler'
              headers: response?.headers
            }

          catch exception
            log.error {
              message: 'Something went wrong during response handling'
              exception: exception
              response: response
            }

          finally

            # Trying to determine where we're stalling
            log.info {
              event: 'request.next'
            }

            next()

      catch exception
        log.error {
          message: 'Something went wrong during request'
          exception: exception
          parameters: parameters
        }

        next()



  # Makes an authenticated request.
  authenticatedRequest: (parameters, handler) ->

    # See https://github.com/reddit/reddit/wiki/API
    if not process.env.USER_AGENT
      message =
      log.error {
        messsage: 'User agent is not defined'
        parameters: parameters
      }

      return handler()

    # Wrap token authentication around the request
    @authenticate (token) =>

      # Don't make the request if the token is not valid
      if not token
        log.error {
          message: 'Access token is not set'
          parameters: parameters
        }

        return handler()

      # User agent should be the only header we need to set for a API requests.
      parameters.headers =
        'User-Agent': process.env.USER_AGENT

      # Set the HTTP basic auth headers for the request
      parameters.auth =
        bearer: @token.token

      @enqueueRequest(parameters, handler)
