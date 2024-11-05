# Use the official Python image.
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your application code
COPY . .

# Expose the new port
EXPOSE 5001

# Mount the Docker volume for data and log
VOLUME ["/app/data", "/app/log"]

# Specify the command to run your application
CMD ["python", "app.py"]
