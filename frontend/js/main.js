/**
 * main.js — Visitor counter
 *
 * Fetches the current visit count from the API Gateway endpoint,
 * increments it server-side via Lambda + DynamoDB, and displays
 * the updated count in the element with id="counter".
 *
 * SETUP: Replace the empty string below with your API Gateway URL
 * after running `sam deploy`. The URL is printed in the SAM output
 * as "ApiUrl" and looks like:
 *   https://<id>.execute-api.<region>.amazonaws.com/prod/counter
 */

const API_URL = 'https://o98zwz137a.execute-api.us-east-1.amazonaws.com/prod/counter';  // <-- paste your SAM ApiUrl output here

const getVisitCount = async () => {
    const counterEl = document.getElementById('counter');

    if (!API_URL) {
        counterEl.innerText = '—';
        console.warn('API_URL is not set in main.js. Deploy the backend and update this value.');
        return;
    }

    try {
        const response = await fetch(API_URL, {
            method: 'GET',
            headers: { 'Content-Type': 'application/json' }
        });

        if (!response.ok) {
            throw new Error(`API responded with status ${response.status}`);
        }

        const data = await response.json();
        counterEl.innerText = data.count.toLocaleString();

    } catch (error) {
        console.error('Failed to fetch visit count:', error);
        counterEl.innerText = '—';
    }
};

document.addEventListener('DOMContentLoaded', getVisitCount);
