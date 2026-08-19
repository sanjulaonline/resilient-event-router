# Build from the repository root so the library can be packed and published to
# the Ballerina local repository before the example is compiled:
#
#   docker build -f examples/sotercare/Dockerfile -t sotercare-alert-router .

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/src
COPY --chown=ballerina:ballerina . .
RUN bal pack && bal push --repository=local
WORKDIR /home/ballerina/src/examples/sotercare
RUN bal build

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /home/ballerina/src/examples/sotercare/target/bin/alert_router.jar ./alert_router.jar
EXPOSE 9090 9091
ENTRYPOINT ["java", "-jar", "alert_router.jar"]
