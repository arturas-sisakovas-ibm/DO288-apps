FROM quay.io/redhattraining/ocpdev-ubi8-openjdk-17-base:1.16 as builder

COPY pom.xml .
RUN mvn dependency:go-offline

COPY src src
RUN mvn clean package

FROM quay.io/redhattraining/ocpdev-ubi8-openjdk-17-base:1.16

COPY --from=builder /home/jboss/target/quarkus-app .

CMD ["java", "-jar", "quarkus-run.jar"]
