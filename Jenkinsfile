pipeline {
    agent any

    parameters {
        string(name: 'IMAGE_NAME', defaultValue: 'amitlubin/nginx', description: 'The docker image intended name')
    }

    environment {
        DOCKER_HUB_CREDENTIALS = credentials('docker-hub-test') // Need to create a user-password credential
        DOCKER_REGISTRY = 'docker.io'
    }

    stages {
        stage ('Opening message'){
            steps {
                script {
                    echo 'Starting the test pipeline'
                    echo 'I will build and push my nginx Docker image to docker hub'
                }
            }
        }

        stage('Generate Timestamp Tag') {
            steps {
                script {
                    def timestamp = sh(
                        script: "date '+%Y%m%d%H%M'",
                        returnStdout: true
                    ).trim()
                    echo "Generated timestamp: ${timestamp}"
                    env.FULL_IMAGE_NAME = "${params.IMAGE_NAME}:${timestamp}"
                }
            }
        }

        stage ('Build the Docker image') {
            steps {
                script {
                    echo "Building the Docker image: ${env.FULL_IMAGE_NAME}"
                    sh "docker build -t ${env.FULL_IMAGE_NAME} ."
                }
            }
        }

        stage('Login to Docker Hub') {
            steps {
                sh "echo $DOCKER_HUB_CREDENTIALS_PSW | docker login -u $DOCKER_HUB_CREDENTIALS_USR --password-stdin"
                echo "Successfully logged in to Docker Hub"
            }
        }

        stage('Push to Docker Hub') {
            steps {
                sh "docker push ${env.FULL_IMAGE_NAME}"
                echo "Successfully pushed the image: ${env.FULL_IMAGE_NAME} to Docker Hub"
            }
        }
    }

    post {
        always {
            script {
                sh "docker rmi ${env.FULL_IMAGE_NAME} || true"
            }
            cleanWs()
        }
    }
}