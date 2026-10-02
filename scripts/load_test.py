"""
scripts/load_test.py
Locust load test script for simulating user traffic against the Application Load Balancer.

Usage:
    pip install locust
    locust -f scripts/load_test.py --host http://<ALB_DNS_NAME>

To run headless (e.g. 50 concurrent users for 5 minutes):
    locust -f scripts/load_test.py --host http://<ALB_DNS_NAME> \
           --users 50 --spawn-rate 5 --run-time 5m --headless
"""

import random
from locust import HttpUser, task, between


class TaskManagerUser(HttpUser):
    # Wait between 1 and 3 seconds between requests
    wait_time = between(1.0, 3.0)

    @task(5)
    def check_health(self):
        """Simulate frequent ALB health checks and monitoring probes."""
        self.client.get("/health", name="/health")

    @task(3)
    def view_info(self):
        """Verify which EC2 instance and AZ served the request."""
        self.client.get("/info", name="/info")

    @task(10)
    def list_tasks(self):
        """Simulate browsing the tasks list."""
        self.client.get("/api/tasks", name="/api/tasks [GET]")

    @task(2)
    def create_and_delete_task(self):
        """Simulate full task creation and deletion cycle."""
        priority = random.choice(["low", "medium", "high"])
        payload = {
            "title": f"Load Test Generated Task #{random.randint(1000, 9999)}",
            "description": "Simulated traffic task created during load test.",
            "priority": priority,
            "status": "pending",
        }

        # Create
        res = self.client.post("/api/tasks", json=payload, name="/api/tasks [POST]")
        if res.status_code == 201:
            task_id = res.json().get("id")
            if task_id:
                # Retrieve
                self.client.get(f"/api/tasks/{task_id}", name="/api/tasks/[id] [GET]")
                # Update status
                self.client.patch(
                    f"/api/tasks/{task_id}",
                    json={"status": "completed"},
                    name="/api/tasks/[id] [PATCH]",
                )
                # Cleanup
                self.client.delete(
                    f"/api/tasks/{task_id}",
                    name="/api/tasks/[id] [DELETE]",
                )
