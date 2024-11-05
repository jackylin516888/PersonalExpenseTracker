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
