#!/bin/bash

# Archive content starts here
mkdir -p expense_tracker_bundle/templates

# Flask application file
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
import re  # Import the regular expression module

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

# Global dictionary to store user data including monthly budget
user_data = {}

# Path to the JSON file where user data will be stored
user_data_file = os.path.join(data_dir, 'users.json')


# Cache to hold the expenses before saving
expense_cache = []

# Path to the csv file where expense data will be stored
expense_data_file = os.path.join(data_dir, 'expenses.csv')

# Token timeout duration
TOKEN_TIMEOUT_MINUTES = 10  # Set the token timeout to 10 minute

def validate_date(date_string):
    """
    This function validates whether a given date string is in the correct format (YYYY-MM-DD).

    :param date_string: The date string to be validated.
    :return: True if the format is correct, False otherwise.
    """
    pattern = re.compile(r'^\d{4}-\d{2}-\d{2}$')
    if not pattern.match(date_string):
        return False
    try:
        datetime.strptime(date_string, '%Y-%m-%d')
        return True
    except ValueError:
        return False

def validate_amount(amount):
    """
    This function validates whether a given amount is a positive float.

    :param amount: The amount to be validated.
    :return: True if the amount is valid, False otherwise.
    """
    try:
        amount_float = float(amount)
        if amount_float >= 0:
            return True
        else:
            return False
    except ValueError:
        return False

def validate_category(category):
    """
    This function validates whether a given category is not empty and contains only alphanumeric characters and spaces.

    :param category: The category to be validated.
    :return: True if the category is valid, False otherwise.
    """
    pattern = re.compile(r'^[a-zA-Z0-9 ]+$')
    if len(category) > 0 and pattern.match(category):
        return True
    else:
        return False

def validate_description(description):
    """
    This function validates whether a given description is not empty.

    :param description: The description to be validated.
    :return: True if the description is valid, False otherwise.
    """
    if len(description) > 0:
        return True
    else:
        return False

# Function to load user data from the JSON file
def load_user_data():
    """
    This function loads user data from the JSON file where user information is stored.
    If the file exists, it reads the data and returns it as a dictionary of user data.
    If the file does not exist, it returns an empty dictionary.

    :return: A dictionary of user data or an empty dictionary if the file doesn't exist.
    """
    global user_data_file

    logging.debug("Loading user data")
    if os.path.exists(user_data_file):
        with open(user_data_file, 'r') as f:
            return json.load(f)
    return {}

# Function to save user data to the JSON file
def save_user_data():
    """
    This function saves the user data to the JSON file without the 'expenses' key for each user.

    """
    global user_data
    global user_data_file
    new_user_data = {}
    for username, user_info in user_data.items():
        if 'password_hash' not in user_info or user_info['password_hash'] is None:
            # Generate a default password hash or handle the situation as needed
            user_info['password_hash'] = generate_password_hash('default_password')  # You can customize the default password

        new_user_info = {
            "password_hash": user_info["password_hash"],
            "monthly_budget": user_info["monthly_budget"]
        }
        new_user_data[username] = new_user_info

    with open(user_data_file, 'w') as f:
        json.dump(new_user_data, f, indent=4)
    logging.debug("User data saved")

# Function to load existing expenses from CSV file
def load_expenses(username=None):
    """
    This function loads the existing expenses from the CSV file.
    If a username is provided, it loads only the expenses for that user.
    If no username is provided, it loads expenses for all users.

    :param username: (Optional) The username for which to load expenses. If None, loads all users' expenses.
    :return: A list of expense dictionaries.
    """
    global expense_data_file
    expenses = []
    if os.path.exists(expense_data_file):
        with open(expense_data_file, 'r', newline='') as csvfile:
            reader = csv.DictReader(csvfile)
            for row in reader:
                if username is None or row['username'] == username:
                    expenses.append(row)
    return expenses

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

# Function to get the monthly budget for a specific user
def get_user_monthly_budget(username):
    """
    This function gets the monthly budget for a specific user.
    If the user data is not in the global `user_data` dictionary, it loads it from the JSON file.

    :param username: The username for which to get the budget.
    :return: The monthly budget for the user.
    """
    global user_data
    if username not in user_data:
        # Load user data from the JSON file
        user_data_json = load_user_data()
        if username in user_data_json:
            user_data[username] = user_data_json[username]

    if username in user_data:
        return user_data[username].get('monthly_budget', 0)
    return 0

def calculate_total_expenses(username):
    global expense_cache
    global expense_data_file

    total_expenses = 0
    current_month = datetime.now().month

    # Calculate from CSV file
    with open(expense_data_file, 'r', newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            if row['username'] == username:
                expense_date = datetime.strptime(row['date'], '%Y-%m-%d')
                if expense_date.month == current_month:
                    total_expenses += float(row['amount'])

    # Calculate from cache
    for expense in expense_cache:
        if expense['username'] == username:
            expense_date = datetime.strptime(expense['date'], '%Y-%m-%d')
            if expense_date.month == current_month:
                total_expenses += expense['amount']

    return total_expenses


# Function to set the monthly budget for a specific user
def set_user_monthly_budget(username, budget):
    global user_data
    if username not in user_data:
        user_data[username] = {}
    user_data[username]['monthly_budget'] = budget
    save_user_data()

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
    global user_data
    logging.debug("Entering register route")
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']

        # Check if the username already exists in the JSON file
        existing_users = load_user_data()
        logging.debug(f"Loaded {len(existing_users)} users for registration check")
        if username in existing_users:
            flash(_("Username already exists. Please choose a different one."), 'error')
            logging.debug("Username already exists")
            return redirect(url_for('register'))

        # Hash the password
        password_hash = generate_password_hash(password)

        # Add the new user to the dictionary of users
        user_data[username] = {
            'password_hash': password_hash,  # Ensure a valid hash is assigned
            'monthly_budget': 0  # Default monthly budget
        }

        # Save the updated user data to the JSON file
        save_user_data()

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
    global user_data
    logging.debug("Entering login route")
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']

        # Check if the username exists in the JSON file
        existing_users = load_user_data()
        logging.debug(f"Loaded {len(existing_users)} users for login check")
        if username not in existing_users:
            flash(_("Invalid username or password. Please try again."), 'error')
            logging.debug("Invalid username")
            return redirect(url_for('login'))

        # Check if the password is correct
        if not check_password_hash(existing_users[username]['password_hash'], password):
            flash(_("Invalid username or password. Please try again."), 'error')
            logging.debug("Invalid password")
            return redirect(url_for('login'))

        # Set the session variable to indicate the user is logged in
        session['logged_in'] = True
        session['username'] = username
        session['login_time'] = datetime.now().isoformat()  # Record the login time

        flash(_("Login successful."),'success')
        logging.debug("Login successful")
        return redirect(url_for('home'))

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
    username = session['username']
    monthly_budget = get_user_monthly_budget(username)
    return render_template('home.html', choices=[
        "1. Add expense",
        "2. View expenses",
        "3. Set monthly budget",
        "4. Track budget",
        "5. Save expenses",
        "6. Exit"
    ], home_url=url_for('home'), monthly_budget=monthly_budget)  # Pass the monthly budget to the template

# Function to add expense
@app.route('/add_expense', methods=['GET', 'POST'])
@login_required
def add_expense():
    """
    This function handles the addition of an expense.
    It validates the input fields before adding the expense to the cache.

    :return: Renders the add_expense.html template with error messages if validation fails.
    """
    global expense_cache
    logging.debug("Entering add_expense route")
    if request.method == 'POST':
        username = session['username']
        expense_description = request.form['description']
        expense_amount = request.form['amount']
        expense_date = request.form['date']
        expense_category = request.form['category']

        # Validate the input fields
        if not validate_date(expense_date):
            flash(_("Invalid date format. Please use YYYY-MM-DD."), 'error')
            return render_template('add_expense.html')

        if not validate_amount(expense_amount):
            flash(_("Invalid amount. Please enter a positive number."), 'error')
            return render_template('add_expense.html')

        if not validate_category(expense_category):
            flash(_("Invalid category. It should contain only alphanumeric characters and spaces and not be empty."), 'error')
            return render_template('add_expense.html')

        if not validate_description(expense_description):
            flash(_("Invalid description. It cannot be empty."), 'error')
            return render_template('add_expense.html')

        # If all validations pass, proceed with adding the expense to the cache
        expense_amount = float(expense_amount)
        expense = {
            'username': username,
            'date': expense_date,
            'category': expense_category,
            'amount': expense_amount,
            'description': expense_description
        }
        expense_cache.append(expense)

        flash(_("Expense added successfully."), 'success')
        return render_template('add_expense.html')

    logging.debug("Rendering add expense template")
    return render_template('add_expense.html')

# Function to view expenses
@app.route('/view_expenses')
@login_required
def view_expenses():
    """
    This function renders the page that displays all the saved and cached expenses for the logged-in user.

    :return: Renders the view_expenses.html template with the list of expenses.
    """
    global expense_cache
    logging.debug("Entering view_expenses route")
    username = session['username']

    existing_expenses = load_expenses(username)
    current_user_cache_expenses = [expense for expense in expense_cache if expense['username'] == username]
    all_expenses = existing_expenses + current_user_cache_expenses

    return render_template('view_expenses.html', expenses=all_expenses)

# Function to set monthly budget
@app.route('/set_monthly_budget', methods=['GET', 'POST'])
@login_required
def set_monthly_budget():
    """
    This function handles the setting of the monthly budget for the logged-in user.
    It validates the budget input before updating the user's budget.

    :return: Renders the set_monthly_budget.html template with error messages if validation fails.
    """
    logging.debug("Entering set_monthly_budget route")
    if request.method == 'POST':
        username = session['username']
        budget = request.form['budget']

        if not validate_amount(budget):
            flash(_("Invalid budget. Please enter a positive number."), 'error')
            return render_template('set_monthly_budget.html')

        budget = float(budget)
        set_user_monthly_budget(username, budget)
        flash(_("Monthly budget set successfully."), 'success')
        logging.debug("Monthly budget set")
        return render_template('set_monthly_budget.html')

    logging.debug("Rendering set_monthly_budget template")
    return render_template('set_monthly_budget.html')

# Function to save expenses
@app.route('/save_expenses')
@login_required
def save_expenses():
    """
    This function saves the expenses for the current user.
    It adds all the cached data for the current user to the existing data and then clears the current user's cache.

    :return: Redirects to the home page after saving the expenses.
    """
    global expense_cache
    global expense_data_file

    username = session['username']
    logging.debug("Entering save_expenses route for user: %s", username)

    existing_expenses = load_expenses()
    current_user_cache_expenses = [expense for expense in expense_cache if expense['username'] == username]

    all_expenses = existing_expenses + current_user_cache_expenses

    with open(expense_data_file, 'w', newline='') as csvfile:
        fieldnames = ['username', 'date', 'category', 'amount', 'description']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for expense in all_expenses:
            writer.writerow(expense)

    # Clear the current user's expenses from the cache
    expense_cache = [expense for expense in expense_cache if expense['username']!= username]

    flash(_("Expenses saved successfully."), 'success')
    return redirect(url_for('home'))

# Function to track_budget
@app.route('/track_budget')
@login_required
def track_budget():
    """
    This function handles the tracking of the user's budget.
    It calculates the total expenses and compares them to the monthly budget.

    :return: Renders the track_budget.html template with budget details.
    """
    username = session['username']
    monthly_budget = get_user_monthly_budget(username)
    total_expenses = calculate_total_expenses(username)
    remaining_budget = monthly_budget - total_expenses

    return render_template('track_budget.html', monthly_budget=monthly_budget, total_expenses=total_expenses, remaining_budget=remaining_budget)

# Function to edit_expense
@app.route('/edit_expense/<expense_id>', methods=['GET', 'POST'])
@login_required
def edit_expense(expense_id):
    """
    This function handles the editing of an existing expense.
    It retrieves the expense by its ID, validates the updated input fields, and saves the changes.

    :param expense_id: The ID of the expense to be edited.
    :return: Redirects to the view expenses page on successful edit or renders the edit expense template with error messages.
    """
    global expense_cache
    username = session['username']

    # Retrieve the expense to be edited
    expense_to_edit = [expense for expense in expense_cache if expense['username'] == username and expense['id'] == expense_id]
    if not expense_to_edit:
        flash(_("Expense not found."), 'error')
        return redirect(url_for('view_expenses'))

    if request.method == 'POST':
        expense_description = request.form['description']
        expense_amount = request.form['amount']
        expense_date = request.form['date']
        expense_category = request.form['category']

        # Validate the input fields
        if not validate_date(expense_date):
            flash(_("Invalid date format. Please use YYYY-MM-DD."), 'error')
            return render_template('edit_expense.html', expense=expense_to_edit[0])

        if not validate_amount(expense_amount):
            flash(_("Invalid amount. Please enter a positive number."), 'error')
            return render_template('edit_expense.html', expense=expense_to_edit[0])

        if not validate_category(expense_category):
            flash(_("Invalid category. It should contain only alphanumeric characters and spaces and not be empty."), 'error')
            return render_template('edit_expense.html', expense=expense_to_edit[0])

        if not validate_description(expense_description):
            flash(_("Invalid description. It cannot be empty."), 'error')
            return render_template('edit_expense.html', expense=expense_to_edit[0])

        # Update the expense in the cache
        expense_to_edit[0]['description'] = expense_description
        expense_to_edit[0]['amount'] = float(expense_amount)
        expense_to_edit[0]['date'] = expense_date
        expense_to_edit[0]['category'] = expense_category

        flash(_("Expense edited successfully."), 'success')
        return redirect(url_for('view_expenses'))

    return render_template('edit_expense.html', expense=expense_to_edit[0])

# Function to delete_expense
@app.route('/delete_expense/<expense_id>', methods=['GET'])
@login_required
def delete_expense(expense_id):
    """
    This function handles the deletion of an expense by its ID.

    :param expense_id: The ID of the expense to be deleted.
    :return: Redirects to the view expenses page after deleting the expense.
    """
    global expense_cache
    username = session['username']

    # Remove the expense from the cache
    expense_cache = [expense for expense in expense_cache if expense['username'] == username and expense['id']!= expense_id]

    flash(_("Expense deleted successfully."), 'success')
    return redirect(url_for('view_expenses'))

# Function to logout
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
    return redirect(url_for('login'))

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

    <h2>Budget Status</h2>
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
    <p>Hello, {{ session['username'] }}!</p>  <!-- Added this line to show the username -->
    <p>Menu:</p>
    <ul>
        <li><a href="{{ url_for('add_expense') }}">1. Add expense</a></li>
        <li><a href="{{ url_for('view_expenses') }}">2. View expenses</a></li>
        <li><a href="{{ url_for('set_monthly_budget') }}">3. Set monthly budget</a></li>
        <li><a href="{{ url_for('track_budget') }}">4. Track budget</a></li>
        <li><a href="{{ url_for('save_expenses') }}">5. Save expenses</a></li>
        <li><a href="{{ url_for('logout') }}">6. Exit</a></li>
    </ul>
    <p>Your monthly budget: {{ monthly_budget }}</p>
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
        <button type="submit" name="add_expense">Add Expense</button>
    </form>
    {% if error %}
        <p>{{ error }}</p>
    {% endif %}
    <a href="{{ url_for('home') }}">Return to Home</a>
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
                <th>Actions</th>
            </tr>
        </thead>
        <tbody>
            {% for expense in expenses %}
            <tr>
                <td>{{ expense.date }}</td>
                <td>{{ expense.category }}</td>
                <td>{{ expense.amount }}</td>
                <td>{{ expense.description }}</td>
                {% if session.get('is_admin', False) %}
                <td>
                    <a href="{{ url_for('edit_expense', expense_id=expense.id) }}">Edit</a>
                    <a href="{{ url_for('delete_expense', expense_id=expense.id) }}">Delete</a>
                </td>
                {% else %}
                <td></td>
                {% endif %}
            </tr>
            {% endfor %}
        </tbody>
    </table>
    <a href="{{ url_for('home') }}">Return to Home</a>
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
    <a href="{{ url_for('home') }}">Return to Home</a>
</body>
</html>
EOF

cat << 'EOF' > expense_tracker_bundle/templates/edit_expense.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Edit Expense</title>
</head>
<body>
    <h1>Edit Expense</h1>
    <form method="post">
        <label for="date">Date (YYYY-MM-DD):</label>
        <input type="date" id="date" name="date" value="{{ expense.date }}" required>
        <label for="category">Category:</label>
        <input type="text" id="category" name="category" value="{{ expense.category }}" required>
        <label for="amount">Amount:</label>
        <input type="number" step="0.01" id="amount" name="amount" value="{{ expense.amount }}" required>
        <label for="description">Description:</label>
        <input type="text" id="description" name="description" value="{{ expense.description }}">
        <button type="submit">Save Changes</button>
    </form>
    {% if error %}
        <p>{{ error }}</p>
    {% endif %}
    <a href="{{ url_for('view_expenses') }}">Cancel and Return to View Expenses</a>
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

cat << 'EOF' > expense_tracker_bundle/templates/track_budget.html
 <!DOCTYPE html>
 <html lang="en">
 <head>
     <meta charset="UTF-8">
     <meta name="viewport" content="width=device-width, initial-scale=1.0">
     <title>Track Budget</title>
 </head>
 <body>
     <h1>Track Your Budget</h1>
     <p>Monthly Budget: {{ monthly_budget }}</p>
     <p>Total Expenses: {{ total_expenses }}</p>
     <p>Remaining Budget: {{ remaining_budget }}</p>
     <a href="{{ url_for('home') }}">Return to Home</a>
 </body>
 </html>
EOF

cat << 'EOF' > expense_tracker_bundle/users.json
{
    "user1": {
        "password_hash": "pbkdf2:sha256:000000$A23bRneljZqnCeyV$d75793d89fca9efe526835f1cc8517f144284ce15dde4ff5e41a599131d3bae1",
        "monthly_budget": 2000.0
    }
    "user2": {
        "password_hash": "pbkdf2:sha256:1111$A23bRneljZqnCeyV$d75793d89fca9efe526835f1cc8517f144284ce15dde4ff5e41a599131d3bae1",
        "monthly_budget": 2000.0
    }
}
EOF

cat << 'EOF' > expense_tracker_bundle/.env
SECRET_KEY=my_secret_key_123
EOF

cat << 'EOF' > expense_tracker_bundle/README.md
# Expense Tracker Application

This is an expense tracking application built with Flask.
![Screenshot of the Expense Tracker Interface](./screenshots/home.jpg)

## Installation
1. Run the `setup_expense_tracker.sh` script. This script will perform the following actions:
    - Handle any necessary self-extraction processes.
    - Clean up any previous installations.
    - Copy existing user data and expense data if any.
    - Move the extracted files to the correct location.
    Example: `./setup_expense_tracker.sh`
2. Build the Docker image using the following command: `./manage.sh [build|rebuild].`
3. Start the container with the `start` command: `./manage.sh start`

## Usage
You can access the application at `http://localhost:5001`.

## Mounting Volumes
The Docker container mounts the `/app/data` directory for CSV files and the `/app/log` directory for logs.

## Routes
- `/`: Home page. Displays interactive menu options.
- `/register`: Registration page.
- `/login`: Login page.
- `/logout`: Logout functionality.
- `/add_expense`: Route for adding an expense.
- `/view_expenses`: Route for viewing all expenses.
- `/set_monthly_budget`: Route for setting the monthly budget.
- `/save_expenses`: Route for saving expenses.
- `/track_budget`: Route for tracking the budget.
- `/edit_expense/<expense_id>`: Route for editing an expense by its ID.
- `/delete_expense/<expense_id>`: Route for deleting an expense by its ID.

## Manage.sh Arguments
- `build`: Build the Docker container and handle self-extraction.
- `debug`: Start the Docker container in debug mode.
- `start`: Start the Docker container.
- `stop`: Stop the Docker container.
- `status`: Check the status of the Docker container.
- `clean`: Clean Docker images.
- `restart`: Restart the Docker container.
- `rebuild`: Rebuild the Docker container.

## Contributors
Shouwei Lin

## License
This project is licensed under the MIT License.
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
        echo "Starting the Docker container in debug mode..."
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
    rebuild)
        echo "Rebuild the Docker container..."

        echo "Stopping the Docker container..."
        docker stop expense_tracker_container
        docker rm expense_tracker_container

        echo "Cleaning Docker images..."
        docker image prune -a -f

        echo "Building the Docker container..."
        docker build -t expense_tracker .
        ;;
    *)
        echo "Usage: $0 {build|debug|start|stop|clean|status|clean|restart}"
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

# Copy screenshots to the final location
if [ -d "screenshots" ]; then
    cp -rf screenshots expense_tracker/screenshots
fi

# Make manage.sh executable
chmod +x expense_tracker/manage.sh

pwd
ls -lhrt
ls -lhrt expense_tracker/*
#cd expense_tracker

# Provide instructions to the user
echo "Files extracted to 'expense_tracker'."
echo "Navigate to 'expense_tracker' and use './manage.sh {build|debug|start|stop|clean|status|clean|restart}' to manage the service."

exit 0

__ARCHIVE_BELOW__