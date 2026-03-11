// lambda/handler.js

const AWS = require('aws-sdk');
const { v4: uuidv4 } = require('uuid');

// Create a DynamoDB client
// AWS SDK automatically uses the Lambda execution role credentials
const dynamo = new AWS.DynamoDB.DocumentClient();

// The main handler function — this is called by API Gateway for every request
// 'event' contains everything about the HTTP request
exports.handler = async (event) => {
  try {
    // Parse the request body (it comes in as a string, we need an object)
    const body = JSON.parse(event.body);

    // Validate required fields
    if (!body.amount || !body.currency) {
      return {
        statusCode: 400,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          error: 'Missing required fields: amount and currency'
        })
      };
    }

    // Build the payment object
    const payment = {
      id:        uuidv4(),                    // Unique payment ID
      amount:    body.amount,                  // e.g. 100
      currency:  body.currency,                // e.g. 'USD'
      status:    'completed',                  // Initial status
      createdAt: new Date().toISOString()      // ISO timestamp
    };

    // Write to DynamoDB
    // process.env.TABLE_NAME was set in Terraform (environment variables)
    await dynamo.put({
      TableName: process.env.TABLE_NAME,
      Item: payment
    }).promise();

    // Return success response
    return {
      statusCode: 201,  // 201 Created
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payment)
    };

  } catch (err) {
    // Log the error — visible in CloudWatch
    console.error('Payment processing error:', err);

    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Internal server error' })
    };
  }
};

