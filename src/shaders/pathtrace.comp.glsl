#version 450

//#define DEBUG

layout (local_size_x = 16, local_size_y = 16) in;
layout (binding=0, rgba8) uniform image2D prev_frame;
layout (binding=1, rgba8) uniform image2D new_frame;

#ifdef DEBUG
layout (binding=2, rgba32f) uniform image2D debug_texture;
#endif

uniform int u_frame;


// *****************************************************************************
// *                              CONSTANTS                                    *
// *****************************************************************************

#define PI 					  3.1415926
#define TWO_PI 				6.2831852
#define FOUR_PI 			12.566370
#define INV_PI 				0.3183099
#define INV_TWO_PI 		0.1591549
#define INV_FOUR_PI 	0.0795775
#define EPSILON       1e-8


// *****************************************************************************
// *                                STRUCTS                                    *
// *****************************************************************************

struct Ray
{
  vec3 origin;
  vec3 dir;
};

struct Light
{
  vec3 position;
};

struct Material
{
  vec3 albedo;
  vec3 emission;
  bool is_microfacet;
};


struct Sphere
{
  vec3 center;
  float radius;
  Material mat;
};

struct Triangle
{
  vec3 p0;
  vec3 p1;
  vec3 p2;
  Material mat;
};

struct Collision
{
  float t;              // distance along ray
  vec3 p;               // world position of collision
  vec3 n;               // surface normal at collision
  bool inside;          // ray inside the object or not
  Material mat;
  Ray ray;
  int object_index;     // index of the object
};

struct Sample
{
  vec3 value;
  float pdf;
};


// *****************************************************************************
// *                                 SCENE                                     *
// *****************************************************************************

Light light = Light(vec3(0, 1, 3));

Material emissive = Material(
  vec3(1, 1, 1),
  vec3(1.0, 0.9, 0.7) * 30.f,
  false
);

Material emissive2 = Material(
  vec3(1, 1, 1),
  vec3(1.0, 0.0, 0.0) * 5.f,
  false
);

Material gray = Material(
  vec3(0.7, 0.7, 0.7),
  vec3(0, 0, 0),
  false
);

Material light_blue = Material(
  vec3(0.9f, 0.75f, 0.9f),
  vec3(0, 0, 0),
  false
);

Material pink = Material(
  vec3(0.955008, 0.637427, 0.538163),
  vec3(0, 0, 0),
  true 
);

Material pink2 = Material(
  vec3(0.75f, 0.9f, 0.9f),
  vec3(0, 0, 0),
  true 
);

Material gold = Material(
  vec3(0.9f, 0.9f, 0.75f),
  vec3(0, 0, 0),
  false
);

Material red = Material(
  vec3(0.7f, 0.1f, 0.1f),
  vec3(0, 0, 0),
  false
);

Material green = Material(
  vec3(0.1f, 0.7f, 0.1f),
  vec3(0, 0, 0),
  false
);

Material blue = Material(
  vec3(0.1f, 0.1f, 0.7f),
  vec3(0, 0, 0),
  false
);

Sphere sphere1 = Sphere(vec3(-3.75, -3.75, -2.5), 1.25, gold);
Sphere sphere2 = Sphere(vec3(0, -3.75, -2.5), 1.25, light_blue);
Sphere sphere3 = Sphere(vec3(3.75, -3.75, -2.5), 1.25, pink);

Triangle floor1 = Triangle(
  vec3(5.1, -5, -5),
  vec3(-5.1, -5, -5),
  vec3(5.1, -5, 0),
  gray
);

Triangle floor2 = Triangle(
  vec3(-5.1, -5, 0),
  vec3(5.1, -5, 0),
  vec3(-5.1, -5, -5),
  gray
);

Triangle ceil1 = Triangle(
  vec3(-5.1, 5 + 1e-3, -5),
  vec3(5.1, 5 + 1e-3, -5),
  vec3(5.1, 5 + 1e-3, 0),
  gray
);

Triangle ceil2 = Triangle(
  vec3(5.1, 5 + 1e-3, 0),
  vec3(-5.1, 5 + 1e-3, 0),
  vec3(-5.1, 5 + 1e-3, -5),
  gray
);

Triangle left1 = Triangle(
  vec3(-5,  -5.1, -5),
  vec3(-5,  5.1, -5),
  vec3(-5,  -5.1,  0),
  red
);

Triangle left2 = Triangle(
  vec3(-5,  5.1, -5),
  vec3(-5,  5.1, 0),
  vec3(-5,  -5.1,  0),
  red
);

Triangle right1 = Triangle(
  vec3( 5,  5.1, -5),
  vec3( 5,  -5.1, -5),
  vec3( 5,  -5.1,  0),
  green
);

Triangle right2 = Triangle(
  vec3( 5,  5.1, 0),
  vec3( 5,  5.1, -5),
  vec3( 5,  -5.1,  0),
  green
);

Triangle back1 = Triangle(
  vec3( -5,  -5, -5),
  vec3( 5,  -5, -5),
  vec3(-5,  5,  -5),
  gray
);

Triangle back2 = Triangle(
  vec3( 5,  -5, -5),
  vec3( 5,  5, -5),
  vec3(-5,  5,  -5),
  gray
);

Triangle light1 = Triangle(
  vec3(-2.5, 5, -3.5),
  vec3(2.5, 5, -1.5),
  vec3(2.5, 5, -3.5),
  emissive
);

Triangle light2 = Triangle(
  vec3(-2.5, 5, -3.5),
  vec3(2.5, 5, -1.5),
  vec3(-2.5, 5, -1.5),
  emissive
);

float camera_pos_z = 7.0;


Collision collisions[42];

vec3 ambient = vec3(0.05, 0.05, 0.05);


// *****************************************************************************
// *                                 UTILS                                     *
// *****************************************************************************

uint rngState;

uint wang_hash(inout uint seed)
{
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

float RandomFloat01(inout uint state)
{
    return float(wang_hash(state)) / 4294967296.0;
}
vec3 local_to_world(vec3 local_dir, vec3 normal)
{
  vec3 binormal = normalize(
    (abs(normal.x) > abs(normal.y))
      ? vec3(normal.z, 0.0, -normal.x)
      : vec3(0.0, -normal.z, normal.y) 
  );

	vec3 tangent = cross(binormal, normal);
    
	return local_dir.x*tangent + local_dir.y*binormal + local_dir.z*normal;
}

void cartesian_to_spherical(in vec3 xyz, out float rho, out float phi, out float theta)
{
  rho = sqrt((xyz.x * xyz.x) + (xyz.y * xyz.y) + (xyz.z * xyz.z));
  phi = asin(xyz.y / rho);
	theta = atan( xyz.z, xyz.x );
}

vec3 spherical_to_cartesian(float rho, float phi, float theta)
{
  float sinTheta = sin(theta);
  return vec3(sinTheta*cos(phi), sinTheta*sin(phi), cos(theta)) * rho;
}


// *****************************************************************************
// *                             COLLISIONS                                    *
// *****************************************************************************

// Adapted from scratchapixel's sphere collision 
Collision collision(Sphere sphere, Ray ray)
{
  Collision obj_col;
  obj_col.inside = false;

  vec3 oc = sphere.center - ray.origin;
  float t_ca = dot(oc, ray.dir);
  float d2 = dot(oc, oc) - t_ca * t_ca;

  // Ray goes outside of sphere
  if (d2 > sphere.radius * sphere.radius) 
  {
    obj_col.t = -1;
    return obj_col;
  }

  float t_hc = sqrt(sphere.radius*sphere.radius - d2);
  float t0 = t_ca - t_hc;
  float t1 = t_ca + t_hc;
  float t_near = min(t0, t1);
  float t_far = max(t0, t1);
  obj_col.t = t_near;

  // Sphere behind the ray, no collision
  if (t_far < 0.0)
  {
    obj_col.t = -1.0;
    return obj_col;
  }

  // Ray inside the sphere
  if (t_near < 0.0)
  {
    obj_col.t = t_far;
    obj_col.inside = true;
  }

  obj_col.p = ray.origin + ray.dir * obj_col.t; 
  obj_col.n = normalize(obj_col.p - sphere.center);
  obj_col.mat = sphere.mat;
  obj_col.ray = ray;

  // Flip normal if ray inside
  if (obj_col.inside) obj_col.n *= -1.0;

  return obj_col;
}

// Möller-Trumbore algorithm : 
//   - express problem in barycentric coordinate P = wA + uB + vC
//   - also : P = O + tD
//   - reorganise equation of collision (unknowns should be t, u, v)
//   - solve system using Cramer's rule
Collision collision(Triangle triangle, Ray ray)
{
  vec3 edge1 = triangle.p1 - triangle.p0;
  vec3 edge2 = triangle.p2 - triangle.p0;

  Collision obj_col;
  obj_col.inside = false;

  vec3 h = cross(ray.dir, edge2);
  float a = dot(edge1, h);

  // Parallel ray and triangle
  if (a > -EPSILON && a < EPSILON)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float f = 1.0 / a;

  vec3 s = ray.origin - triangle.p0;
  float u = dot(s, h) * f;
  if (u < 0.0 || u > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  vec3 q = cross(s, edge1);
  float v = dot(ray.dir, q) * f;
  if (v < 0.0 || u + v > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float t = dot(edge2, q) * f;
  if (t < EPSILON)
  {
    obj_col.t = -1;
    return obj_col;
  }

  obj_col.t = t;
  obj_col.p = ray.origin + ray.dir * obj_col.t; 
  obj_col.n = normalize(cross(edge1, edge2));
  obj_col.mat = triangle.mat;
  obj_col.ray = ray;

  return obj_col;
}

Collision intersect_scene(Ray ray)
{
  int n = 0;
  collisions[n] = collision(sphere1, ray); n++;
  collisions[n] = collision(sphere2, ray); n++;
  collisions[n] = collision(sphere3, ray); n++;
  collisions[n] = collision(floor1, ray); n++;
  collisions[n] = collision(floor2, ray); n++;
  collisions[n] = collision(ceil1, ray); n++;
  collisions[n] = collision(ceil2, ray); n++;
  collisions[n] = collision(left1, ray); n++;
  collisions[n] = collision(left2, ray); n++;
  collisions[n] = collision(right1, ray); n++;
  collisions[n] = collision(right2, ray); n++;
  collisions[n] = collision(back1, ray); n++;
  collisions[n] = collision(back2, ray); n++;
  collisions[n] = collision(light1, ray); n++;
  collisions[n] = collision(light2, ray); n++;

  float infinity = 1.0 / 0.0;
  float min_val = infinity;
  int min_i = -1;
  for (int i = 0; i < n; i++)
  {
    if (collisions[i].t > 0 && min_val > collisions[i].t)
    {
      min_val = collisions[i].t;
      min_i = i;
    }
  }
  min_i = (min_i == -1) ? 0 : min_i;
  return collisions[min_i];
}


// *****************************************************************************
// *                                 BSDF                                      *
// *****************************************************************************

Sample sample_hemisphere(vec3 n, vec2 u)
{
  vec2 r = vec2(u.x,u.y) * TWO_PI;
	vec3 dr = vec3(sin(r.x) * vec2(sin(r.y), cos(r.y)), cos(r.x));
	vec3 wi = dot(dr, n) * dr;

  float pdf = INV_TWO_PI;
  
  return Sample(wi, pdf);
}

Sample cosine_sample_hemisphere(vec3 n, vec2 u)
{
  vec3 dir;
  float r = sqrt(u.x);
  float phi = TWO_PI * u.y;
  dir.x = r * cos(phi);
  dir.y = r * sin(phi);
  dir.z = sqrt(max(0.0, 1.0 - dir.x * dir.x - dir.y * dir.y));
  vec3 wi = local_to_world(dir, n);

  float pdf = abs(dot(wi, n)) * INV_PI;  // FIXME only if same hemisphere

  return Sample(wi, pdf);
}

// This is the lambert one only for now
vec3 evaluate_lambert_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  //return obj_col.mat.albedo;
  return obj_col.mat.albedo * INV_PI;
}

vec3 f0 = vec3(1.00, 0.71, 0.29); //Pre-computed (default is water value)
//vec3 f0 = vec3(0.05);
float roughness = 0.05;
float metalness = 1.0;// = 0.1;//1 if metallic 0 otherwise

// Use dotNH for microdetails
vec3 fresnelSchlick(float dotHV, vec3 albedo)
{
  //vec3 F0 = f0;
  vec3 F0 = mix(f0, albedo, metalness);
  vec3 f90 = vec3(1.0);//Pre-computed (here we use water value)
  return F0 + (f90 - F0) * pow(1.0 - dotHV, 5.0);
}

float distribGGX(float dotNH, float alpha2)
{
  float dotNH2 = pow(dotNH, 2.0);
  float bot = dotNH2 * (alpha2 - 1.0) + 1.0;
  return alpha2 / (PI * bot * bot + EPSILON);
}

float geometrySmith(float dotNV, float dotNL, float alpha2)
{
  float kdirect = pow(roughness + 1.0, 2.0) / 8.0;
  float kIBL = alpha2 / 2.0;
  float k = kdirect;
  float Gobstruction = dotNV / (dotNV * (1.0 - k) + k);
  float Gshadowing = dotNL / (dotNL * (1.0 - k) + k);
  return Gshadowing * Gobstruction;
}

vec3 evaluate_cook_torrance_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  //temporary
  vec3 lightPos = vec3(0.0, 3.0, 3.0);
  vec3 lightColor = vec3(1.0, 1.0, 1.0);

  //bissector of v and lightdir
  vec3 h = normalize(wi + wo);

  //Storing results
  float dotNV = max(abs(dot(obj_col.n, wo)), 0.0);
  float dotNL = max(dot(obj_col.n, wi), 0.0);
  float dotVN = max(dot(wo, obj_col.n), 0.0);
  float dotNH = max(dot(obj_col.n, h), 0.0);
  float dotLH = max(dot(wi, h), 0.0);
  float dotVH = max(dot(wo, h), 0.0);
  float alpha = roughness * roughness;
  float alpha2 = alpha * alpha;

  //Calculating Normal Distribution
  float nDistrib = distribGGX(dotNH, alpha2);

  //Calculate Schlick Fresnel approximation
  //Represents ks
  vec3 nFresnel = fresnelSchlick(dotLH, obj_col.mat.albedo); 

  //Calculate Smith GGX 
  float nGeometric = geometrySmith(dotNV, dotNL, alpha2);

  //Computing Cook-Torrance GGX model
  vec3 specular = (nDistrib * nFresnel * nGeometric) /
    (4.0 * dotNV * dotNL + EPSILON);

  //Computing diffuse Lambert
  vec3 kd = vec3(1.0);
  kd = (kd - nFresnel) * (1.0 - metalness);
  vec3 diffuse = kd * obj_col.mat.albedo / PI;

  vec3 color = (diffuse + specular) * dotNL;
  color = color / (color + vec3(1.0));
  color = pow(color, vec3(1.0 / 2.2));

  return color;
}

vec3 evaluate_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  if (obj_col.mat.is_microfacet)
    return evaluate_cook_torrance_bsdf(wo, wi, obj_col);
  else
    return evaluate_lambert_bsdf(wo, wi, obj_col);
}


// *****************************************************************************
// *                               LIGHTS                                      *
// *****************************************************************************

vec2 uniform_sample_triangle(vec2 u)
{
  float su0 = sqrt(u.x);
  return vec2(1 - su0, u.y * su0);
}

Sample area_sample(Triangle t, vec3 origin)
{
  vec2 u = vec2(RandomFloat01(rngState), RandomFloat01(rngState));
  vec2 b = uniform_sample_triangle(u);

  vec3 sample_pt =  t.p0 * b.x + t.p1 * b.y + t.p2 * (1 - b.x - b.y); 

  vec3 dir = normalize(sample_pt - origin);

  // Compute area of triangle
  vec3 n = cross(t.p1 - t.p0, t.p2 - t.p0);
  float area_pdf = 2 / length(n);     // 1/area : uniform sampling over area

  return Sample(dir, area_pdf);
}

// *** NOTE *** : Multiple Importance Sampling (MIS) could be added here
vec3 uniform_sample_one_light(Collision obj_col)
{
  // TODO: pick random light
  Triangle light = RandomFloat01(rngState) > 0.5 ? light1 : light2;

  // Sample a ray direction from light to collision point
  Sample light_sample = area_sample(light, obj_col.p);
  vec3 wi = light_sample.value;


  // Add small displacement to prevent being on the surface
  Ray ray_in = Ray(
    obj_col.p + obj_col.n * 1.0e-2 * ((dot(wi, obj_col.n) < 0) ? -1.0 : 1.0),
    wi
  );

  Collision light_col = intersect_scene(ray_in);

  // Discard if no hit or hit non emissive object 
  if (light_col.t <= 0 || light_col.mat.emission == vec3(0)) return vec3(0);
  
  // Evaluate the BSDF at the object's collision 
  vec3 wo = -obj_col.ray.dir;
  vec3 f = evaluate_bsdf(wo, wi, obj_col);

  // Convert area pdf to solid angle pdf
  // Intuition: adding distance / smaller angle from point to light -> smaller angle range on point hemisphere
  float pdf = light_sample.pdf * (light_col.t * light_col.t) / abs(dot(light_col.n, -wi));

  if (f == vec3(0) || pdf == 0) return vec3(0);

  return light_col.mat.emission * f * abs(dot(wi, obj_col.n)) / pdf;
}


// *****************************************************************************
// *                               MAIN                                        *
// *****************************************************************************

vec3 pathtrace(Ray ray)
{
  vec3 L = vec3(0);                    // Total radiance estimate
  vec3 throughput = vec3(1);           // Current path throughput

  int max_bounces = 8;
  bool specular_bounce = false;

  for (int bounces = 0; ; bounces++)
  {
    // Intersect ray with scene
    Collision obj_col = intersect_scene(ray);

    // Stop if no collision or no more bounce
    if (obj_col.t <= 0 || bounces >= max_bounces)
    {
      L += throughput * vec3(0.05);
      break;
    }

    // Account for the emission only if :
    //  - it is the initial collision
    //  - previous was specular BSDF so no direct illumination estimate (Dirac distribution) 
    // Other cases are handled by direct lighting estimation
    if (bounces == 0 || specular_bounce)
    {
      if (obj_col.t > 0)
      {
        L += throughput * obj_col.mat.emission;
      }
      else
      {
        // TODO: infinite area light sources
        L += vec3(0);
      }
    }

    // TODO: Compute scattering functions and skip over medium boundaries

    // Direct lighting estimation at current path vertex (end of the current path = light)
    L += throughput * uniform_sample_one_light(obj_col);

    // Indirect lighting estimation

    // Sample the BSDF at intersection to get the new path direction
    vec2 u = vec2(RandomFloat01(rngState), RandomFloat01(rngState));
    Sample bsdf_sample = cosine_sample_hemisphere(obj_col.n, u);

    vec3 wi = bsdf_sample.value;
    vec3 wo = -ray.dir;
    vec3 f = evaluate_bsdf(wo, wi, obj_col);

    // Update how much light is received from next path vertex
    throughput *= f * abs(dot(wi, obj_col.n)) / bsdf_sample.pdf;

    // Add small displacement to prevent being on the surface
    ray = Ray(
      obj_col.p + obj_col.n * 1.0e-2 * ((dot(wi, obj_col.n) < 0) ? -1.0 : 1.0),
      wi
    );

    // Russian roulette : save computing resources by terminating paths in an unbiased way
    float p = max(throughput.r, max(throughput.g, throughput.b));
    if (RandomFloat01(rngState) > p)
        break;

    // Add the energy we 'lose' by randomly terminating paths
    throughput *= 1.0f / p;            

  }

  return L;
}

void main()
{
  rngState = uint(uint(gl_GlobalInvocationID.x) * uint(1973)
    + uint(gl_GlobalInvocationID.y) * uint(9277)
    + uint(u_frame) * uint(26699)) | uint(1);

  int width = int(gl_NumWorkGroups.x); // one workgroup = one invocation = one pixel
  int height = int(gl_NumWorkGroups.y);
  width = 1024;
  height = 1024;
  ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
  
  // Convert this pixel's screen space location to world space
  float x_pixel = 2.0 * pixel.x / width - 1.0;
  float y_pixel = 2.0 * pixel.y / height - 1.0;
  vec3 pixel_world = vec3(x_pixel, y_pixel, camera_pos_z - 1.0);
  
  // Get this pixel's world-space ray
  Ray ray;
  ray.origin = vec3(0.0, 0.0, camera_pos_z);
  ray.dir = normalize(pixel_world - ray.origin);

  // Cast the ray out into the world and intersect the ray with objects
  int spp = 1;
  vec3 res = vec3(0);
  for (int i = 0; i < spp; i++)
  {
    res += 1.0 / float(spp) * pathtrace(ray);
  } 

  float blend = 1.0 / (float(u_frame + 1));

  vec3 acc_color = mix(
    imageLoad(prev_frame, pixel).rgb,
    res,
    blend
  );

  imageStore(new_frame, pixel, vec4(acc_color.xyz, 1.0));

  #ifdef DEBUG
  imageStore(debug_texture, pixel, vec4(res, 1.0));
  #endif
}