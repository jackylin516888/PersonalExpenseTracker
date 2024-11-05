# Expense Tracker Application

This is an expense tracking application built with Flask.

## Installation
1. Run the `manage.sh` script with the `build` command to build the Docker container.
2. Start the container with the `start` command.

## Usage
You can access the application at `http://localhost:5001`.

## Mounting Volumes
The Docker container mounts the `/app/data` directory for CSV files and the `/app/log` directory for log.

## Routes
- `/`: Home page. display interactive menu options
- `/register`: Registration page.
- `/login`: Login page.
- `/logout`: Logout functionality.

## Contributors
Your Name

## License
MIT License
