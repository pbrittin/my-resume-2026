# Use the official AWS SAM build image for Python 3.12
FROM public.ecr.aws/sam/build-python3.12

# Install pytest (and any other test plugins you need)
RUN pip install pytest pytest-mock

# Set the working directory
WORKDIR /var/task
