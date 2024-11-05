#!/bin/bash

# Archive content starts here
mkdir -p expense_tracker_bundle/templates

cat << 'EOF' > expense_tracker_bundle/app.py
'''
This is the main application file for the Personal Expense Tracker.
It contains the Flask application setup and various functions for expense management.
'''
import csv
import json
import logging
import os
from datetime import datetime, timedelta  # Added timedelta for token timeout

from dotenv import load_dotenv
from flask import Flask, render_template, request, redirect, url_for, flash, session
from flask_babel import gettext as _
from werkzeug.security import generate_password_hash, check_password_hash
from functools import wraps
from flask_babel import Babel

app = Flask(__name__)
babel = Babel(app)
# Set the default locale
app.config['BABEL_DEFAULT_LOCALE'] = 'en_US'

# Create the log directory if it doesn't exist
log_dir = os.path.join(app.root_path, 'log')
if not os.path.exists(log_dir):
    os.makedirs(log_dir)

data_dir = os.path.join(app.root_path, 'data')
if not os.path.exists(data_dir):
    os.makedirs(data_dir)

# Configure logging
logging.basicConfig(
    filename=os.path.join(log_dir, 'app.log'),
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Load environment variables
load_dotenv()
app.secret_key = os.getenv('SECRET_KEY')

# Global list to store expenses
expenses = []
# Global variable to store the monthly budget
monthly_budget = 0

# Path to the JSON file where user data will be stored
user_data_file = os.path.join(data_dir, 'users.json')

# Token timeout duration
TOKEN_TIMEOUT_MINUTES = 10  # Set the token timeout to 10 minute

# Function to validate the date format
def validate_date(date_string):
    """
    This function validates whether a given date string is in the correct format (YYYY-MM-DD).

    :param date_string: The date string to be validated.
    :return: True if the format is correct, False otherwise.
    """
    try:
        datetime.strptime(date_string, '%Y-%m-%d')
        return True
    except ValueError:
        return False

# Function to load user data from the JSON file
def load_user_data():
    """
    This function loads user data from the JSON file where user information is stored.
    If the file exists, it reads the data and returns it as a list of user dictionaries.
    If the file does not exist, it returns an empty list.

    :return: A list of user dictionaries containing user data or an empty list if the file doesn't exist.
    """
    logging.debug("Loading user data")
    if os.path.exists(user_data_file):
        with open(user_data_file, 'r') as f:
            return json.load(f)
    return []

# Function to save user data to the JSON file
def save_user_data(users):
    """
    This function saves the provided list of user data (as dictionaries) to the JSON file.

    :param users: A list of user dictionaries to be saved to the JSON file.
    """
    with open(user_data_file, 'w') as f:
        json.dump(users, f, indent=4)
    logging.debug("User data saved")

# Function to check if the token has timed out
def has_token_timed_out():
    """
    Checks if the session token has timed out.

    :return: True if timed out, False otherwise.
    """
    if 'login_time' in session:
        login_time = datetime.fromisoformat(session['login_time'])
        current_time = datetime.now()
        time_difference = current_time - login_time
        return time_difference > timedelta(minutes=TOKEN_TIMEOUT_MINUTES)
    return True

### 2. Registration Logic
@app.route('/register', methods=['GET', 'POST'])
def register():
    """
    This function handles the user registration process.
    When a POST request is received, it takes the username and password from the form data,
    validates if the username already exists, hashes the password, and saves the new user data to the JSON file.
    If the request is GET, it renders the registration form template.

    :return: Redirects to the login page on successful registration or renders the registration form.
    """
    logging.debug("Entering register route")
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']

        # Check if the username already exists in the JSON file
        users = load_user_data()
        logging.debug(f"Loaded {len(users)} users for registration check")
        for user in users:
            if user['username'] == username:
                flash(_("Username already exists. Please choose a different one."), 'error')
                logging.debug("Username already exists")
                return redirect(url_for('register'))

        # Hash the password
        password_hash = generate_password_hash(password)

        # Add the new user to the list of users
        new_user = {
            'username': username,
            'password_hash': password_hash
        }
        users.append(new_user)

        # Save the updated list of users to the JSON file
        save_user_data(users)

        flash(_("Registration successful. You can now log in."),'success')
        logging.debug("Registration successful")
        return redirect(url_for('login'))

    logging.debug("Rendering register template")
    return render_template('register.html')

### 3. Login Logic
@app.route('/login', methods=['GET', 'POST'])
def login():
    """
    This function handles the user login process.
    When a POST request is received, it takes the username and password from the form data,
    checks if the username exists in the JSON file, and verifies if the password is correct.
    If the login is successful, it sets the session variables and redirects to the home page.
    If the request is GET, it renders the login form template.

    :return: Redirects to the home page on successful login or renders the login form.
    """
    logging.debug("Entering login route")
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']

        # Check if the username exists in the JSON file
        users = load_user_data()
        logging.debug(f"Loaded {len(users)} users for login check")
        for user in users:
            if user['username'] == username:
                # Check if the password is correct
                if check_password_hash(user['password_hash'], password):
                    # Set the session variable to indicate the user is logged in
                    session['logged_in'] = True
                    session['username'] = username
                    session['login_time'] = datetime.now().isoformat()  # Record the login time

                    flash(_("Login successful."),'success')
                    logging.debug("Login successful")
                    return redirect(url_for('home'))
                else:
                    flash(_("Invalid username or password. Please try again."), 'error')
                    logging.debug("Invalid password")
                    return redirect(url_for('login'))

        flash(_("Invalid username or password. Please try again."), 'error')
        logging.debug("Invalid username")
        return redirect(url_for('login'))

    logging.debug("Rendering login template")
    return render_template('login.html')

### 4. Protecting Routes
# We need to protect the routes that should only be accessible to logged-in users. We'll create a decorator function for this purpose.
def login_required(func):
    """
    This is a decorator function that protects routes by checking if the user is logged in.
    If the user is not logged in, it flashes an error message and redirects to the login page.
    If the user is logged in, it allows access to the decorated route function.

    :param func: The route function to be protected.
    :return: A wrapper function that performs the login check before calling the original route function.
    """
    @wraps(func)  # This line preserves the original function's name and docstring
    def wrapper(*args, **kwargs):
        if 'logged_in' not in session or not session['logged_in'] or has_token_timed_out():  # Check for token timeout
            flash(_("You must be logged in to access this page. Your session has timed out. Please log in again."), 'error')
            return redirect(url_for('login'))
        return func(*args, **kwargs)
    return wrapper

### 5. Applying the Login Requirement to Routes
# Modify the existing routes that should be protected:
@app.route('/')
@login_required
def home():
    """
    This function renders the home page of the expense tracker application.
    It provides a menu of options for the logged-in user to perform various actions such as adding expenses,
    viewing expenses, setting a monthly budget, etc.

    :return: Renders the home.html template with the available menu options and a link to return home.
    """
    logging.debug("Entering home route")
    return render_template('home.html', choices=[
        "1. Add expense",
        "2. View expenses",
        "3. Set monthly budget",
        "4. Track budget",
        "5. Save expenses",
        "6. Exit"
    ], home_url=url_for('home'))  # Pass the home URL to the template


@app.route('/add_expense', methods=['GET', 'POST'])
@login_required
def add_expense():
    """
    This function handles the addition of an expense.
    When a POST request is received, it validates the input fields (date, category, amount, and description),
    checks if the date format is correct, and if all validations pass, adds the expense to the global expenses list
    and redirects to the home page. If the request is GET, it renders the add_expense.html template which is a form
    for the user to enter expense details.

    :return: Redirects to the home page on successful expense addition or renders the add_expense form with appropriate error messages.
    """
    logging.debug("Entering add_expense route")
    if request.method == 'POST':
        date = request.form['date']
        category = request.form['category']
        amount = float(request.form['amount'])
        description = request.form['description']

        # Validate required fields and input values
        if not date or not category or amount <= 0:
            flash(_("Please fill in all required fields and enter a valid positive amount."), 'error')
            logging.debug("Invalid expense input")
            return render_template('add_expense.html', home_url=url_for('home'), error="Please fill in all required fields and enter a valid positive amount.")

        if not validate_date(date):
            flash(_("Invalid date format. Please use YYYY-MM-DD."), 'error')
            logging.debug("Invalid date format")
            return render_template('add_expense.html', home_url=url_for('home'), error="Invalid date format. Please use YYYY-MM-DD.")

        expense = {
            'date': date,
            'category': category,
            'amount': amount,
            'description': description
        }
        expenses.append(expense)
        logging.debug("Expense added successfully")
        return redirect(url_for('home'))

    logging.debug("Rendering add_expense template")
    return render_template('add_expense.html', home_url=url_for('home'))

@app.route('/view_expenses')
@login_required
def view_expenses():
    """
    This function renders the page that displays all the stored expenses.
    It passes the global expenses list to the view_expenses.html template for rendering and a link to return home.

    :return: Renders the view_expenses.html template with the list of expenses and a link to return home.
    """
    logging.debug("Entering view_expenses route")
    return render_template('view_expenses.html', expenses=expenses, home_url=url_for('home'))  # Pass the home URL to the template

@app.route('/set_monthly_budget', methods=['GET', 'POST'])
@login_required
def set_monthly_budget():
    """
    This function handles the setting of the monthly budget.
    When a POST request is received, it updates the global monthly_budget variable with the value entered by the user
    and redirects to the home page. If the request is GET, it renders the set_monthly_budget.html template which is a form
    for the user to enter the budget amount.

    :return: Redirects to the home page on successful budget setting or renders the set_monthly_budget form with a link to return home.
    """
    logging.debug("Entering set_monthly_budget route")
    if request.method == 'POST':
        global monthly_budget
        monthly_budget = float(request.form['budget'])
        logging.debug("Monthly budget set")
        return redirect(url_for('home'))
    logging.debug("Rendering set_monthly_budget template")
    return render_template('set_monthly_budget.html', home_url=url_for('home'))  # Pass the home URL to the template

@app.route('/track_budget')
@login_required
def track_budget():
    """
    This function calculates and displays the budget status.
    It sums up the amounts of all expenses in the global expenses list and compares it with the monthly budget.
    Based on the comparison, it sets the appropriate status message and renders the track_budget.html template
    with the status message.

    :return: Renders the track_budget.html template with the budget status message and a link to return home.
    """
    logging.debug("Entering track_budget route")
    total_expenses = sum(expense['amount'] for expense in expenses)
    if total_expenses > monthly_budget:
        status = "You have exceeded your budget!"
    else:
        remaining_budget = monthly_budget - total_expenses
        status = f"You have {remaining_budget} left for the month."
    logging.debug("Budget status calculated")
    return render_template('track_budget.html', status=status, home_url=url_for('home'))  # Pass the home URL to the template

@app.route('/save_expenses')
@login_required
def save_expenses():
    """
    This function saves the expenses to a CSV file.
    It creates a CSV writer and writes the header and each expense record from the global expenses list to the file.
    After saving, it redirects to the home page.

    :return: Redirects to the home page after saving the expenses to the CSV file.
    """
    logging.debug("Entering save_expenses route")
    filename = os.path.join(data_dir, 'expenses.csv')
    with open(filename, 'w', newline='') as csvfile:
        fieldnames = ['date', 'category', 'amount', 'description']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for expense in expenses:
            writer.writerow(expense)
    logging.debug("Expenses saved")
    return redirect(url_for('home'))

### 6. Logout Logic
@app.route('/logout')
def logout():
    """
    This function handles the logout process.
    It clears the relevant session variables (logged_in and username) and flashes a logout message.
    Then it redirects the user to the login page.

    :return: Redirects to the login page after clearing the session variables.
    """
    session.pop('logged_in', None)
    session.pop('username', None)
    session.pop('login_time', None)  # Remove the login time when logging out
    flash(_("You have been logged out."), 'info')
    logging.debug("Logout successful")
    return redirect

if __name__ == "__main__":
    app.run(debug=True, host='0.0.0.0', port=5001)
EOF

cat << 'EOF' > expense_tracker_bundle/templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Expense Tracker</title>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f4f4f4; color: #333; padding: 20px; }
        h1 { color: #2c3e50; }
        form { background-color: #ffffff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        label { display: block; margin: 5px 0; }
        input { width: 100%; padding: 10px; margin-bottom: 10px; border: 1px solid #ccc; border-radius: 4px; }
        button { background-color: #3498db; color: white; border: none; padding: 10px 20px; border-radius: 5px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Expense Tracker</h1>

    <form method="post">
        <h2>Add Expense</h2>
        <label for="date">Date:</label>
        <input type="date" id="date" name="date" required>

        <label for="category">Category:</label>
        <input type="text" id="category" name="category" required>

        <label for="amount">Amount:</label>
        <input type="number" step="0.01" id="amount" name="amount" required>

        <label for="description">Description:</label>
        <input type="text" id="description" name="description">

        <button type="submit" name="add_expense">Add Expense</button>
    </form>

    <form method="post">
        <h2>Set Monthly Budget</h2>
        <label for="budget">Budget:</label>
        <input type="number" step="0.01" id="budget" name="budget" required>
        <button type=" submit" name="set_budget">Set Budget</button>
    </form>

    <h2>Expenses</h2>
    <table>
        <thead>
            <tr>
                <th>Date</th>
                <th>Category</th>
                <th>Amount</th>
                <th>Description</th>
            </tr>
        </thead>
        <tbody>
            {% for expense in expenses %}
            <tr>
                <td>{{ expense.date }}</td>
                <td>{{ expense.category }}</td>
                <td>{{ expense.amount }}</td>
                <td>{{ expense.description }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <h2>Budget Status</h>
    <p>You have set a budget of {{ monthly_budget }}</p>
    <a href="{{ url_for('track_budget') }}">Track Budget</a>

</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/home.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Personal Expense Tracker - Home</title>
</head>
<body>
    <h1>Personal Expense Tracker</h1>
    <p>Menu:</p>
    <ul>
        <li><a href="{{ url_for('add_expense') }}">1. Add expense</a></li>
        <li><a href="{{ url_for('view_expenses') }}">2. View expenses</a></li>
        <li><a href="{{ url_for('set_monthly_budget') }}">3. Set monthly budget</a></li>
        <li><a href="{{ url_for('track_budget') }}">4. Track budget</a></li>
        <li><a href="{{ url_for('save_expenses') }}">5. Save expenses</a></li>
        <li><a href="{{ url_for('logout') }}">6. Exit</a></li>
    </ul>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/add_expense.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Add Expense</title>
</head>
<body>
    <h1>Add Expense</h1>
    <form method="post">
        <label for="date">Date (YYYY-MM-DD):</label>
        <input type="date" id="date" name="date" required>
        <label for="category">Category:</label>
        <input type="text" id="category" name="category" required>
        <label for="amount">Amount:</label>
        <input type="number" step="0.01" id="amount" name="amount" required>
        <label for="description">Description:</label>
        <input type="text" id="description" name="description">
        <button type="submit">Add Expense</button>
    </form>
    {% if error %}
        <p>{{ error }}</p>
    {% endif %}
    <button><a href="{{ home_url }}">Go to Home</a></button>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/view_expenses.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>View Expenses</title>
</head>
<body>
    <h1>View Expenses</h1>
    <table>
        <thead>
            <tr>
                <th>Date</th>
                <th>Category</th>
                <th>Amount</th>
                <th>Description</th>
            </tr>
        </thead>
        <tbody>
            {% for expense in expenses %}
            <tr>
                <td>{{ expense.date }}</td>
                <td>{{ expense.category }}</td>
                <td>{{ expense.amount }}</td>
                <td>{{ expense.description }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/set_monthly_budget.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Set Monthly Budget</title>
</head>
<body>
    <h1>Set Monthly Budget</h1>
    <form method="post">
        <label for="budget">Budget:</label>
        <input type="number" step="0.01" id="budget" name="budget" required>
        <button type="submit">Set Budget</button>
    </form>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/track_budget.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Track Budget</title>
</head>
<body>
    <h1>Budget Status</h1>
    <p>{{ status }}</p>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/register.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Register</title>
</head>
<body>
    <h1>Register</h1>
    <form method="post">
        <label for="username">Username:</label>
        <input type="text" id="username" name="username" required>

        <label for="password">Password:</label>
        <input type="password" id="password" name="password" required>

        <button type="submit">Register</button>
    </form>
    <a href="{{ url_for('login') }}">Already have an account? Login</a>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/login.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login</title>
</head>
<body>
    <h1>Login</h1>
    <form method="post">
        <label for="username">Username:</label>
        <input type="text" id="username" name="username" required>

        <label for="password">Password:</label>
        <input type="password" id="password" name="password" required>

        <button type="submit">Login</button>
    </form>
    <a href="{{ url_for('register') }}">Don't have an account? Register</a>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/users.json
[
    {
        "username": "user1",
        "password_hash": "hashed_password_1"
    },
    {
        "username": "user2",
        "password_hash": "hashed_password_2"
    }
]
EOF

cat << 'EOF' > expense_tracker_bundle/.env
SECRET_KEY=my_secret_key_123
EOF

cat << 'EOF' > expense_tracker_bundle/README.md
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
EOF

cat << 'EOF' > expense_tracker_bundle/Dockerfile
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
EOF


cat << 'EOF' > expense_tracker_bundle/requirements.txt
Flask==2.0.1
flask_babel==4.0.0
python-dotenv==1.0.1
Werkzeug==2.0.1
EOF

# Create the manage.sh script
cat << 'EOF' > expense_tracker_bundle/manage.sh
#!/bin/bash

case "$1" in
    build)
        echo "Building the Docker container..."
        docker build -t expense_tracker .
        ;;
    debug)
        echo "Starting the Docker container..."
        docker run -p 5001:5001 --name expense_tracker_container -v $(pwd)/data:/app/data -v $(pwd)/log:/app/log expense_tracker
        ;;
    start)
        echo "Starting the Docker container..."
        docker run -d -p 5001:5001 --name expense_tracker_container -v $(pwd)/data:/app/data -v $(pwd)/log:/app/log expense_tracker
        ;;
    stop)
        echo "Stopping the Docker container..."
        docker stop expense_tracker_container
        docker rm expense_tracker_container
        ;;
    status)
        echo "Checking the status of the Docker container..."
        docker ps -a | grep expense_tracker_container
        ;;
    clean)
        echo "Cleaning Docker images..."
        docker image prune -a -f
        ;;
    restart)
        echo "Restarting the Docker container..."
        docker restart expense_tracker_container
        ;;
    *)
        echo "Usage: $0 {build|start|stop|status|clean|restart}"
        exit 1
esac
EOF

# Self-extracting script
ARCHIVE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' $0)
tail -n+$ARCHIVE $0 | tar -xz

pwd
ls -lhrt
ls -lhrt expense_tracker/*

# Clean up any previous installation
if [ -d "expense_tracker/data" ]; then
    mv expense_tracker/data expense_tracker_bundle/data
    rm -rf expense_tracker
elif [ -d "expense_tracker" ]; then
    rm -rf expense_tracker
fi

# Move extracted files to the final location
mv expense_tracker_bundle expense_tracker

# Make manage.sh executable
chmod +x expense_tracker/manage.sh

pwd
ls -lhrt
ls -lhrt expense_tracker/*
#cd expense_tracker

# Provide instructions to the user
echo "Files extracted to 'expense_tracker'."
echo "Navigate to 'expense_tracker' and use './manage.sh {build|start|stop|status}' to manage the service."

exit 0

__ARCHIVE_BELOW__