# AWS Cloud Resume Challenge

A serverless resume website hosted on AWS, featuring a live visitor counter.

## Architecture

```
GitHub (OIDC — no stored credentials)
    └──> GitHub Actions
              ├── Deploy frontend ──> S3 (private) ──> CloudFront (HTTPS + custom domain)
              └── Deploy backend  ──> AWS SAM
                        └── API Gateway + Lambda (Python 3.12) + DynamoDB
```

## Stack

| Layer | Service |
|---|---|
| Frontend hosting | S3 + CloudFront |
| HTTPS / CDN / Custom domain | CloudFront + ACM |
| API | API Gateway (REST) |
| Compute | Lambda (Python 3.12) |
| Database | DynamoDB (on-demand) |
| IaC | AWS SAM (CloudFormation) |
| CI/CD | GitHub Actions + OIDC |

## Project Structure

```
aws-resume/
├── frontend/
│   ├── index.html          ← Your resume (you provide this)
│   ├── css/styles.css
│   ├── images/             ← Add me.png here
│   └── js/main.js
├── backend/
│   ├── template.yaml       ← SAM infrastructure definition
│   ├── samconfig.toml      ← SAM deploy configuration (generated on first deploy)
│   ├── counter_function/
│   │   ├── app.py          ← Lambda handler
│   │   └── requirements.txt
│   └── tests/
│       └── test_counter.py
└── .github/
    └── workflows/
        ├── frontend.yml
        └── backend.yml
```

## Setup Order

1. Follow the step-by-step guide in `aws-cloud-resume-challenge.md`
2. Complete AWS prerequisites (CLI, SAM CLI, OIDC provider, IAM roles)
3. Add your `index.html` to `frontend/`
4. Add your profile photo as `frontend/images/me.png`
5. Run `sam deploy --guided` from `backend/` for the first deploy
6. Update `API_URL` in `frontend/js/main.js` with the SAM output URL
7. Update CORS origin in `backend/template.yaml` and `backend/counter_function/app.py` with your CloudFront domain
8. Push to GitHub — Actions handles all subsequent deploys

## Local Testing

```bash
# Run unit tests
cd backend
pip install pytest boto3
pytest tests/ -v

# Invoke Lambda locally (requires Docker)
cd backend
sam build
sam local invoke CounterFunction
```

## CI/CD

- Push to `main` with changes in `frontend/` → triggers frontend workflow
- Push to `main` with changes in `backend/` → triggers backend workflow (tests run first)
- Both workflows authenticate to AWS via OIDC — no AWS credentials stored in GitHub
